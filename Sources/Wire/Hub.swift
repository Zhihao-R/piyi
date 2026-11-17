import Foundation
import Synchronization

/// The app end: waits on the socket for each browser's relay to connect, sends fetch requests and receives results for the app, and listens for the relay saying something new is in the inbox.
/// One blocking-read thread per connection; all state is under a lock, so any thread can call
public final class Hub: Sendable {
    /// A connected browser (with the extension installed and running)
    public struct Browser: Sendable, Equatable {
        /// The browser that launched the relay: Google Chrome, Microsoft Edge, Arc…
        public var name: String
        /// The version the extension reports, which the app uses to decide whether to have it reload
        public var version: String?
    }

    public enum Event: Sendable {
        /// The connected browsers changed (connected, disconnected, extension reported its version)
        case browsers([Browser])
        /// The inbox may have something new: "Collect to Piyi" was just clicked in a browser, or a relay just connected (whatever it collected while disconnected is stored there)
        case arrived
    }

    public enum Failure: LocalizedError {
        case noBrowser, disconnected, timedOut, page(String)
        public var errorDescription: String? {
            switch self {
            case .noBrowser: String(localized: "没有连上的浏览器")
            case .disconnected: String(localized: "浏览器在抓取途中断开了")
            case .timedOut: String(localized: "浏览器读这个网页超时了")
            case .page(let why): why
            }
        }
    }

    private final class Connection: Sendable {
        let channel: Channel
        let browser: Mutex<Browser>
        init(_ channel: Channel, _ browser: Browser) { self.channel = channel; self.browser = Mutex(browser) }
    }

    private struct State {
        var connections: [Connection] = []
        var pending: [String: (connection: Connection, reply: CheckedContinuation<Message, Error>)] = [:]
        var server: Int32?
    }

    private let directory: URL
    private let state = Mutex(State())
    private let onEvent: @Sendable (Event) -> Void

    public init(directory: URL = Bridge.directory, onEvent: @escaping @Sendable (Event) -> Void) {
        self.directory = directory
        self.onEvent = onEvent
    }

    public var browsers: [Browser] { state.withLock { $0.connections.map { $0.browser.withLock { $0 } } } }

    /// Start listening
    public func start() throws {
        Bridge.prepare(directory)
        guard let server = listenSocket(Bridge.socket(in: directory)) else { throw CocoaError(.fileWriteNoPermission) }
        state.withLock { $0.server = server }
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(server, nil, nil)
                if fd < 0 { if errno == EINTR { continue } else { return } }
                Thread.detachNewThread { [self] in serve(Channel(fd: fd)) }
            }
        }
    }

    /// Stop listening and disconnect all relays (they reconnect every second, so they connect next time the app opens)
    public func stop() {
        let (server, connections) = state.withLock { s in
            defer { s.server = nil; s.connections = [] }
            return (s.server, s.connections)
        }
        if let server { close(server) }
        for connection in connections { shutdown(connection.channel.fd, SHUT_RDWR) }
        unlink(Bridge.socket(in: directory))
    }

    /// Have a connected browser open a URL in the background and read the page: prefer the one given (your default browser, where you're signed in), otherwise the most recently connected
    public func fetch(_ url: URL, scroll: Bool, prefer: String? = nil, timeout: Duration = .seconds(75)) async throws -> Message {
        try await ask(Message(.fetch, url: url.absoluteString, scroll: scroll), prefer: prefer, timeout: timeout)
    }

    /// Have a connected browser request a URL with its sign-in state (no tab opened) and return the raw response. Browser choice follows the same rule as fetch
    public func request(_ url: URL, prefer: String? = nil, timeout: Duration = .seconds(20)) async throws -> String {
        try await ask(Message(.request, url: url.absoluteString), prefer: prefer, timeout: timeout).body ?? ""
    }

    /// Send a request to the extension and wait for its result (matched by ID)
    private func ask(_ request: Message, prefer: String?, timeout: Duration) async throws -> Message {
        let id = UUID().uuidString
        var message = request
        message.id = id
        let sent = message
        return try await withThrowingTaskGroup(of: Message.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { reply in
                    // Picking a connection and registering for the reply happen under the same lock: the chosen connection can't drop in between and leave a request nobody answers
                    let connection = self.state.withLock { s -> Connection? in
                        guard let c = s.connections.last(where: { $0.browser.withLock { $0.name } == prefer }) ?? s.connections.last else { return nil }
                        s.pending[id] = (c, reply)
                        return c
                    }
                    guard let connection else { return reply.resume(throwing: Failure.noBrowser) }
                    connection.channel.writeLine(sent.encoded)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            do {
                let result = try await group.next()!
                guard result.ok == true else { throw Failure.page(result.error ?? String(localized: "浏览器没读到这个网页")) }
                return result
            } catch {
                // Timeout: the waiting half is still pending, so finish it off
                state.withLock { $0.pending.removeValue(forKey: id) }?.reply.resume(throwing: error)
                throw error
            }
        }
    }

    /// Send to the extension in a given browser (to reload it, etc.); when browser is nil, send to all connected ones (replies are matched by ID; extensions that don't know the ID ignore it)
    public func send(_ message: Message, to browser: String? = nil) {
        let targets = state.withLock { $0.connections.filter { browser == nil || $0.browser.withLock { $0.name } == browser } }
        for connection in targets { connection.channel.writeLine(message.encoded) }
    }

    // MARK: One connection

    private func serve(_ channel: Channel) {
        guard let first = channel.readLine().flatMap(Message.decode), first.type == .relay else { return channel.close() }
        let connection = Connection(channel, Browser(name: first.browser ?? String(localized: "浏览器")))
        changed { $0.connections.append(connection) }
        onEvent(.arrived)
        while let line = channel.readLine() {
            guard let message = Message.decode(line) else { continue }
            switch message.type {
            case .hello:
                changed { _ in connection.browser.withLock { $0.version = message.version } }
            case .result:
                state.withLock { $0.pending.removeValue(forKey: message.id ?? "") }?.reply.resume(returning: message)
            case .collect:
                onEvent(.arrived)
            default:
                break
            }
        }
        let orphans = changed { s in
            s.connections.removeAll { $0 === connection }
            let mine = s.pending.filter { $0.value.connection === connection }
            for id in mine.keys { s.pending.removeValue(forKey: id) }
            return mine.values.map(\.reply)
        }
        for reply in orphans { reply.resume(throwing: Failure.disconnected) }
        channel.close()
    }

    /// Change the connection list, then report the latest browser list to the app
    @discardableResult
    private func changed<T>(_ change: (inout State) -> T) -> T {
        let (result, browsers) = state.withLock { s in
            let result = change(&s)
            return (result, s.connections.map { $0.browser.withLock { $0 } })
        }
        onEvent(.browsers(browsers))
        return result
    }
}
