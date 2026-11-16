import AppKit
import Observation
import Library
import Wire

/// 浏览器扩展在 App 这一端：等中转程序连上来、把登记文件写进各浏览器、把扩展文件装到固定的地方、报连接状态
@MainActor @Observable
final class BrowserExtension {
    enum Status: Equatable {
        /// 连着：是哪几个浏览器
        case connected([String])
        /// 连过，现在没连上：浏览器没开，或者扩展被关掉了
        case idle
        /// 从没连上过
        case absent
    }

    /// 支持的浏览器：名字、应用编号、扩展页地址、数据目录（相对 ~/Library/Application Support，登记文件写在它下面）
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
    /// 连没连过是这台 Mac 上浏览器的事，不跟着资料库走，所以记在 UserDefaults
    private(set) var everConnected = UserDefaults.standard.bool(forKey: everConnectedKey)
    private static let everConnectedKey = "extensionConnected"

    var status: Status {
        if !browsers.isEmpty { return .connected(browsers.map(\.name)) }
        return everConnected ? .idle : .absent
    }

    /// 装给浏览器的扩展文件夹：你在扩展页加载的就是它。App 更新时原地换成新版，浏览器重新加载即可，不用再装一次
    let folder = Bridge.directory.appending(path: "Extension", directoryHint: .isDirectory)

    @ObservationIgnored private var hub: Hub!
    @ObservationIgnored private(set) var reader: BrowserReader!
    /// 这次运行里已经让哪些浏览器重新加载过：加载的不是装好的那个文件夹时，版本永远对不上，不能一直重载
    @ObservationIgnored private var reloaded: Set<String> = []
    @ObservationIgnored private var onArrive: () -> Void = {}
    @ObservationIgnored private var onConnect: () -> Void = {}

    init() {
        // 连接中心的事来自各条连接的线程：排进一条队，按到达的顺序在主线程上逐个处理，连上、断开挨得很近时也不会乱序
        let (events, arrive) = AsyncStream.makeStream(of: Hub.Event.self)
        hub = Hub { arrive.yield($0) }
        reader = BrowserReader(hub: hub)
        Task { [weak self] in for await event in events { self?.handle(event) } }
    }

    /// 装扩展文件、写登记文件、开始等中转程序。onArrive 在本机收件箱里可能来了新的时候调用（浏览器里点了「收进片羽」，或者中转程序刚连上）；
    /// onConnect 在从没有能用的浏览器变成有的时候调用：连着、而且扩展已经是新版（要重新加载的那个会断开一下，不能这时交活给它）
    func start(onArrive: @escaping () -> Void, onConnect: @escaping () -> Void) {
        self.onArrive = onArrive
        self.onConnect = onConnect
        install()
        register()
        do { try hub.start() } catch { NSLog("片羽：扩展的连接没能开始监听：\(error)") }
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

    /// 收件箱里这一条查过重了，把要显示的那句话回给等着的扩展。不是扩展存的编号没有扩展认，发了也无妨
    func answer(_ id: String, _ receipt: Receipt, taking source: Source) {
        hub.send(Message(.collected, id: id, ok: receipt.kept, say: receipt.text(taking: source)))
    }

    // MARK: 装扩展、登记

    /// App 里带的扩展：打包后在 Contents/Resources/Extension，开发时用源码目录里打包好的 dist
    static let bundled: URL? = [
        Bundle.main.resourceURL?.appending(path: "Extension"),
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Extension/dist").standardized,
    ].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }

    private static func version(of folder: URL?) -> String? {
        guard let folder, let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["version_name"] as? String
    }

    /// 装好的和 App 里带的版本不一样就换成新版（版本号是打包时算的源码指纹）
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
            NSLog("片羽：扩展文件没装上：\(error)")
        }
    }

    /// 有能交活的浏览器：扩展报了版本，是新版；或者这次已经让它重新加载过还对不上（加载的是别的文件夹），那就照用
    private var ready: Bool {
        let current = Self.version(of: folder)
        return browsers.contains { $0.version != nil && ($0.version == current || reloaded.contains($0.name)) }
    }

    /// 连上来的扩展不是最新版：让它重新加载（从装好的文件夹读新文件）
    private func reloadOutdated() {
        let current = Self.version(of: folder)
        for browser in browsers where browser.version != nil && browser.version != current && !reloaded.contains(browser.name) {
            reloaded.insert(browser.name)
            hub.send(Message(.reload), to: browser.name)
        }
    }

    /// 告诉各浏览器：扩展可以启动哪个本机程序。每次启动都写一遍，App 挪了位置也能找到；只写装了的浏览器，内容没变不碰
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

    // MARK: 安装指引用

    /// 装了的浏览器（按支持列表的顺序）
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

/// 借浏览器做事的实现：交给你的默认浏览器（登录状态在那里），它没连上就交给别的。
/// 打开网页要排队：一次只读一个，每一页的超时从轮到它才开始算；请求接口不开标签页，不用排
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
            // 排队或读的时候浏览器断开了（关了浏览器、扩展更新重新加载）：和没连上一样，等它再连上
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

    /// 默认浏览器的名字，和中转程序报来的一样（应用名去掉 .app）
    private static var defaultBrowser: String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.deletingPathExtension().lastPathComponent
    }

    /// 排队：前一件做完才开始下一件
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
