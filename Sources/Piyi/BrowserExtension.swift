import AppKit
import Observation
import Library
import Wire

/// The browser extension on the App side: wait for the relay to connect, write manifest files into each browser, install the extension files in a fixed place, report connection status
@MainActor @Observable
final class BrowserExtension {
    enum Status: Equatable {
        /// Connected: which browsers
        case connected([String])
        /// Connected before, not now: the browser isn't open, or the extension was turned off
        case idle
        /// Never connected
        case absent
    }

    /// Supported browsers: name, bundle ID, extensions page URL, data directory (relative to ~/Library/Application Support; manifest files are written under it)
    struct SupportedBrowser: Identifiable {
        var name: String, bundleID: String, extensionsPage: String, dataFolder: String
        var id: String { bundleID }
        var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    }

    static let supported = [
        SupportedBrowser(name: "Google Chrome", bundleID: "com.google.Chrome", extensionsPage: "chrome://extensions", dataFolder: "Google/Chrome"),
        SupportedBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", extensionsPage: "edge://extensions", dataFolder: "Microsoft Edge"),
        SupportedBrowser(name: "Arc", bundleID: "company.thebrowser.Browser", extensionsPage: "chrome://extensions", dataFolder: "Arc/User Data"),
    ]

    private(set) var browsers: [Hub.Browser] = []
    /// Whether it has connected is about the browsers on this Mac, not the library, so it's stored in UserDefaults
    private(set) var everConnected = UserDefaults.standard.bool(forKey: everConnectedKey)
    private static let everConnectedKey = "extensionConnected"

    var status: Status {
        if !browsers.isEmpty { return .connected(browsers.map(\.name)) }
        return everConnected ? .idle : .absent
    }

    /// The extension folder installed for browsers: the one you load on the extensions page. On App updates it's replaced in place with the new version; the browser just reloads, no reinstall needed
    let folder = Bridge.directory.appending(path: "Extension", directoryHint: .isDirectory)

    @ObservationIgnored private var hub: Hub!
    @ObservationIgnored private(set) var reader: BrowserReader!
    /// Browsers already asked to reload in this run: if what's loaded isn't the installed folder, the version will never match, so don't keep reloading
    @ObservationIgnored private var reloaded: Set<String> = []
    @ObservationIgnored private var onArrive: () -> Void = {}
    @ObservationIgnored private var onConnect: () -> Void = {}

    init() {
        // Connection-center events come from each connection's thread: put them in one queue and handle them one by one on the main thread in arrival order, so connects and disconnects close together never get out of order
        let (events, arrive) = AsyncStream.makeStream(of: Hub.Event.self)
        hub = Hub { arrive.yield($0) }
        reader = BrowserReader(hub: hub)
        Task { [weak self] in for await event in events { self?.handle(event) } }
    }

    /// Install extension files, write manifest files, start waiting for the relay. onArrive is called when something new may have arrived in the local inbox ("Collect to Piyi" clicked in the browser, or the relay just connected);
    /// onConnect is called when going from no usable browser to having one: connected, and the extension is already the new version (one that has to reload disconnects briefly, so don't hand it work then)
    func start(onArrive: @escaping () -> Void, onConnect: @escaping () -> Void) {
        self.onArrive = onArrive
        self.onConnect = onConnect
        install()
        register()
        do { try hub.start() } catch { NSLog("Piyi: the extension connection couldn't start listening: \(error)") }
    }

    private func handle(_ event: Hub.Event) {
        switch event {
        case .browsers(let list):
            let wasReady = ready
            browsers = list
            if !list.isEmpty, !everConnected {
                everConnected = true
                UserDefaults.standard.set(true, forKey: Self.everConnectedKey)
            }
            let isReady = ready
            reloadOutdated()
            if !wasReady, isReady { onConnect() }
        case .arrived:
            onArrive()
        }
    }

    /// This inbox item has been deduplicated; send the sentence to show back to the waiting extension. IDs not stored by the extension have no extension to claim them; sending is harmless
    func answer(_ id: String, _ receipt: Receipt, taking source: Source) {
        hub.send(Message(.collected, id: id, ok: receipt.kept, say: receipt.text(taking: source)))
    }

    // MARK: Installing the extension, registration

    /// The extension bundled in the App: in Contents/Resources/Extension when packaged, the built dist in the source directory during development
    static let bundled: URL? = [
        Bundle.main.resourceURL?.appending(path: "Extension"),
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Extension/dist").standardized,
    ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }

    private static func version(of folder: URL?) -> String? {
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["version_name"] as? String
    }

    /// Replace with the new version if the installed one differs from the one bundled in the App (the version is a fingerprint of the source computed at packaging)
    private func install() {
        guard let bundled = Self.bundled, Self.version(of: bundled) != Self.version(of: folder) else { return }
        Bridge.prepare(Bridge.directory)
        let staging = Bridge.directory.appending(path: "Extension-new")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: bundled, to: staging)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.moveItem(at: staging, to: folder)
        } catch {
            NSLog("Piyi: couldn't install the extension files: \(error)")
        }
    }

    /// There's a browser that can take work: the extension reported its version and it's the new one; or it was already asked to reload this run and still doesn't match (it loads a different folder), so use it as is
    private var ready: Bool {
        let current = Self.version(of: folder)
        return browsers.contains { $0.version != nil && ($0.version == current || reloaded.contains($0.name)) }
    }

    /// The connected extension isn't the latest: ask it to reload (reading the new files from the installed folder)
    private func reloadOutdated() {
        let current = Self.version(of: folder)
        for browser in browsers where browser.version != nil && browser.version != current && !reloaded.contains(browser.name) {
            reloaded.insert(browser.name)
            hub.send(Message(.reload), to: browser.name)
        }
    }

    /// Tell each browser which local program the extension may launch. Written on every launch so it's found even if the App moved; only for installed browsers, and untouched if unchanged
    private func register() {
        guard let executable = Bundle.main.executableURL else { return }
        let relay = executable.deletingLastPathComponent().appending(path: "PiyiRelay")
        let manifest: [String: Any] = [
            "name": Bridge.hostName,
            "description": "片羽的扩展中转程序",
            "path": relay.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Bridge.extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        for browser in Self.supported {
            let base = URL.applicationSupportDirectory.appending(path: browser.dataFolder)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            let hosts = base.appending(path: "NativeMessagingHosts")
            let file = hosts.appending(path: "\(Bridge.hostName).json")
            guard (try? Data(contentsOf: file)) != data else { continue }
            try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: For the installation guide

    /// Installed browsers (in the order of the supported list)
    var installedBrowsers: [SupportedBrowser] { Self.supported.filter { $0.app != nil } }

    func openExtensionsPage(in browser: SupportedBrowser) {
        guard let app = browser.app, let page = URL(string: browser.extensionsPage) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: configuration)
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// Doing things through the browser: hand it to your default browser (where you're logged in), or another one if it isn't connected.
/// Opening pages is queued: one at a time, each page's timeout starts when its turn comes; API requests don't open tabs and aren't queued
final class BrowserReader: PageBrowser {
    private let hub: Hub
    private let line = Line()

    init(hub: Hub) { self.hub = hub }

    func render(_ url: URL, scroll: Bool) async throws -> RenderedPage? {
        guard !hub.browsers.isEmpty else { return nil }
        let hub = hub
        do {
            return try await line.run {
                let page = try await hub.fetch(url, scroll: scroll, prefer: Self.defaultBrowser)
                return RenderedPage(url: page.url.flatMap(URL.init(string:)) ?? url, html: page.html ?? "")
            }
        } catch Hub.Failure.noBrowser, Hub.Failure.disconnected {
            // The browser disconnected while queued or reading (browser closed, extension reloaded after an update): same as not connected, wait for it to reconnect
            return nil
        }
    }

    func request(_ url: URL) async throws -> String? {
        guard !hub.browsers.isEmpty else { return nil }
        do {
            return try await hub.request(url, prefer: Self.defaultBrowser)
        } catch Hub.Failure.noBrowser, Hub.Failure.disconnected {
            return nil
        }
    }

    /// Name of the default browser, same as the relay reports (app name without .app)
    private static var defaultBrowser: String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.deletingPathExtension().lastPathComponent
    }

    /// Queue: start the next job only after the previous one is done
    private actor Line {
        private var tail: Task<Void, Never>?

        func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
            let previous = tail
            let task = Task { await previous?.value; return try await work() }
            tail = Task { _ = try? await task.value }
            return try await task.value
        }
    }
}
