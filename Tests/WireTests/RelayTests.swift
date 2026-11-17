import Testing
import Foundation
import CoreGraphics
import ImageIO
import Synchronization
import Library
@testable import Wire

/// A fake browser launches the relay like Chrome does, sends and receives over the browser protocol, and plays the extension;
/// the App side uses the real Hub. Directories are temporary, so the App in use isn't touched
@Suite(.serialized) struct RelayTests {
    let directory = URL.temporaryDirectory.appending(path: "bridge-\(UUID().uuidString.prefix(8))")

    /// Everything collected lands in the inbox before replying; if the App isn't open, wait for it, and tell it to look as soon as the relay connects. Files are deleted by the collecting side once saved, not here
    @Test func collectsLandInInboxBeforeTheAck() async throws {
        let browser = try FakeBrowser(directory)
        defer { browser.close() }
        browser.send(Message(.collect, id: "c1", url: "https://example.com/offline", html: "<p>离线</p>"))
        #expect(try await browser.next(.collected).queued == true, "App 没开：存下，等它打开")
        #expect(inbox().count == 1)

        let events = Events()
        let hub = Hub(directory: directory, onEvent: events.record)
        try hub.start()
        defer { hub.stop() }
        try await events.wait { $0.arrivals == 1 }
        browser.send(Message(.collect, id: "c2", url: "https://example.com/online"))
        #expect(try await browser.next(.collected).queued == false, "App 开着：一样先存下")
        try await events.wait { $0.arrivals == 2 }
        #expect(inbox().count == 2)

        // The App has checked for duplicates and replies to the extension with the text to show, by ID
        hub.send(Message(.collected, id: "c2", ok: true, say: "已经收过，提到了最前"))
        #expect(try await browser.next(.collected).say == "已经收过，提到了最前")
    }

    /// The inbox can't be written: honestly reply that it wasn't saved; the extension must not say "Saved"
    @Test func failedSaveIsReportedAsFailure() async throws {
        // Where the inbox should be there's a file, so it can't be written
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: Bridge.inbox(in: directory).path))
        let browser = try FakeBrowser(directory)
        defer { browser.close() }
        browser.send(Message(.collect, id: "c1", url: "https://example.com/a", html: "<p>x</p>"))
        let ack = try await browser.next(.collected)
        #expect(ack.ok == false && ack.queued == nil && ack.say?.hasPrefix("没存下") == true)
    }

    /// The main path: right-click an image on a web page → the extension sends the image and its page → the relay saves it to the inbox → the App collects it into the library → the staged copy is deleted.
    /// The extension is played by the fake browser; everything else is real: the relay, Hub, inbox, collecting (Intake), library
    @Test func imageFromExtensionBecomesACard() async throws {
        let events = Events()
        let hub = Hub(directory: directory, onEvent: events.record)
        try hub.start()
        defer { hub.stop() }
        let browser = try FakeBrowser(directory)
        defer { browser.close() }
        try await events.wait { $0.arrivals == 1 }

        browser.send(Message(.collect, id: "c1", url: "https://example.com/gallery", image: png()))
        #expect(try await browser.next(.collected).queued == false)
        try await events.wait { $0.arrivals == 2 }

        let store = try Store(root: URL.temporaryDirectory.appending(path: "piyi-test-\(UUID().uuidString)"))
        let intake = Intake(store: store, extractor: Extractor())
        let receipts = Mutex<[Receipt]>([])
        await Inbox(folder: Bridge.inbox(in: directory)).drain { arrival in
            #expect(arrival.id == "c1")
            let outcomes = try? await intake.collect(arrival.sources, report: { event in
                if case .judged(let receipt) = event { receipts.withLock { $0.append(receipt) } }
            })
            return outcomes.map(Intake.saved) ?? false
        }

        let faces = try await store.cards(in: .all).map(\.face)
        #expect(faces.map(\.kind) == [.image])
        let card = try #require(try await store.card(faces[0].id))
        #expect(card.sourceURL == "https://example.com/gallery", "所在网页记作出处")
        #expect(card.url == nil && card.cover != nil, "图片按内容查重，不按所在网页")
        #expect(card.extraction == .complete && card.partial == nil)
        #expect(receipts.withLock { $0 } == [Receipt(new: 1)], "收集确实跑了，回话是「新收了一样」")
        #expect(inbox().isEmpty, "卡存好了，暂存删掉")
    }

    @Test func fetchRoundTripWithTwoBrowsersAndReconnect() async throws {
        let events = Events()
        var hub = Hub(directory: directory, onEvent: events.record)
        try hub.start()
        let a = try FakeBrowser(directory, name: "甲"), b = try FakeBrowser(directory, name: "乙")
        defer { a.close(); b.close() }
        try await events.wait { $0.browsers.count == 2 && $0.browsers.allSatisfy { $0.version != nil } }

        // About 2 MB of whole-page HTML comes back the same way
        let started = Date()
        let page = try await hub.fetch(URL(string: "https://www.xiaohongshu.com/explore/demo")!, scroll: false)
        #expect(page.html?.utf8.count ?? 0 > 2_000_000)
        // About 0.1 s on its own; when run with other tests the machine is busy, so leave plenty of margin. What this guards against is large messages reading slower and slower (an earlier approach took 2.7 s)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(a.fetches.count + b.fetches.count == 1)

        // The App quits and reopens: the relay reconnects by itself and resends the extension's hello
        hub.stop()
        hub = Hub(directory: directory, onEvent: events.record)
        try hub.start()
        defer { hub.stop() }
        try await events.wait { $0.browsers.count == 2 && $0.browsers.allSatisfy { $0.version != nil } }
        _ = try await hub.fetch(URL(string: "https://example.com/second")!, scroll: true)
        #expect(a.fetches.count + b.fetches.count == 2)
        #expect((a.fetches + b.fetches).contains { $0.url == "https://example.com/second" && $0.scroll == true })

        // A request over 1 MB: the relay blocks it and replies with a failure, the extension never gets it, and the connection stays up
        await #expect(throws: Hub.Failure.self) {
            try await hub.fetch(URL(string: "https://example.com/" + String(repeating: "x", count: 1_100_000))!, scroll: false)
        }
        #expect(a.fetches.count + b.fetches.count == 2)
        #expect(hub.browsers.count == 2)
    }

    @Test func pageFailureAndDisconnectReachTheCaller() async throws {
        let events = Events()
        let hub = Hub(directory: directory, onEvent: events.record)
        try hub.start()
        defer { hub.stop() }
        await #expect(throws: Hub.Failure.self) { try await hub.fetch(URL(string: "https://example.com")!, scroll: false) }

        let browser = try FakeBrowser(directory, failing: true)
        try await events.wait { !$0.browsers.isEmpty }
        await #expect(throws: Hub.Failure.page("页面打不开")) { try await hub.fetch(URL(string: "https://example.com")!, scroll: false) }

        browser.mute = true
        let pending = Task { try await hub.fetch(URL(string: "https://example.com/slow")!, scroll: false) }
        try await Task.sleep(for: .milliseconds(200))
        browser.close()
        await #expect(throws: Hub.Failure.disconnected) { try await pending.value }
    }

    @Test func socketIsPrivate() throws {
        let hub = Hub(directory: directory) { _ in }
        try hub.start()
        defer { hub.stop() }
        let mode = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int ?? 0o777) & 0o077 }
        #expect(mode(Bridge.socket(in: directory)) == 0)
        #expect(mode(directory.path) == 0)
    }

    private func inbox() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: Bridge.inbox(in: directory), includingPropertiesForKeys: nil)) ?? []
    }
}

/// A small image
func png() -> Data {
    let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

extension Hub.Failure: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.errorDescription == b.errorDescription }
}

/// Events reported by the Hub
final class Events: Sendable {
    private let state = Mutex<(browsers: [Hub.Browser], arrivals: Int)>(([], 0))

    var browsers: [Hub.Browser] { state.withLock { $0.browsers } }
    /// How many times it was told to look at the inbox
    var arrivals: Int { state.withLock { $0.arrivals } }

    func record(_ event: Hub.Event) {
        state.withLock {
            switch event {
            case .browsers(let list): $0.browsers = list
            case .arrived: $0.arrivals += 1
            }
        }
    }

    /// Waits until the condition holds, at most 5 seconds (the relay reconnects once a second)
    func wait(_ condition: (Events) -> Bool) async throws {
        for _ in 0..<50 where !condition(self) { try await Task.sleep(for: .milliseconds(100)) }
        try #require(condition(self))
    }
}

/// Launches the relay like a browser and plays the extension: says hello, and answers fetch requests with a page of about 2 MB
final class FakeBrowser: @unchecked Sendable {
    private let relay = Process()
    private let input = Pipe(), output = Pipe()
    private let received = Mutex<[Message]>([])
    let failing: Bool
    /// Doesn't answer fetch requests (simulates a fetch cut off midway)
    var mute: Bool { get { muted.withLock { $0 } } set { muted.withLock { $0 = newValue } } }
    private let muted = Mutex(false)

    var fetches: [Message] { received.withLock { $0.filter { $0.type == .fetch } } }

    init(_ directory: URL, name: String = "假浏览器", failing: Bool = false) throws {
        self.failing = failing
        relay.executableURL = try Self.relayBinary()
        relay.environment = ["PIYI_BRIDGE": directory.path]
        relay.standardInput = input
        relay.standardOutput = output
        relay.standardError = FileHandle.nullDevice
        try relay.run()
        _ = writer
        Thread.detachNewThread { [self] in answer() }
        send(Message(.hello, version: name))
    }

    private lazy var writer = Channel(fd: input.fileHandleForWriting.fileDescriptor)

    func send(_ message: Message) { writer.writeFrame(message.encoded) }

    /// Waits for the relay to send a certain kind of message
    func next(_ type: Message.Kind) async throws -> Message {
        for _ in 0..<50 {
            if let found = received.withLock({ list in list.firstIndex { $0.type == type }.map { list.remove(at: $0) } }) { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }

    func close() {
        try? input.fileHandleForWriting.close()
        relay.waitUntilExit()
    }

    private func answer() {
        let channel = Channel(fd: output.fileHandleForReading.fileDescriptor)
        while let frame = channel.readFrame(), let message = Message.decode(frame) {
            received.withLock { $0.append(message) }
            guard message.type == .fetch, !mute else { continue }
            send(failing ? Message(.result, id: message.id, ok: false, error: "页面打不开")
                 : Message(.result, id: message.id, url: message.url, html: String(repeating: "拼", count: 700_000), ok: true))
        }
    }

    /// The built relay is in the same directory as the test bundle
    static func relayBinary() throws -> URL {
        let dirs = [Bundle(for: FakeBrowser.self), Bundle.main].map { $0.bundleURL.deletingLastPathComponent() }
        return try #require(dirs.map { $0.appending(path: "PiyiRelay") }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}
