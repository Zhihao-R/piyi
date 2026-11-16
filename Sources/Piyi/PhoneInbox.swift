import AppKit
import Library

/// 手机收件箱：iCloud 云盘里「快捷指令」文件夹下的 PiyiInbox。手机上的快捷指令「收集片羽」把分享来的链接、文字、图片、文件存进去，
/// 同步到这台 Mac 后在这里收。文件夹有变化、App 回到前台时各看一遍；App 没开时文件留在 iCloud 里，打开后补收。
/// 和本机收件箱是同一种做法（Library 的 Inbox）：原件等内容存进资料库才删
@MainActor @Observable
final class PhoneInbox {
    /// 快捷指令「收集片羽」的分享链接：引导里做成二维码给手机扫
    static let shortcut = URL(string: "https://www.icloud.com/shortcuts/8b7c043f5c534adba30d949475279ba2")!
    /// 放在「快捷指令」自己的文件夹里：快捷指令按「它自己的文件夹」记这个位置，不绑账号，分享给别人添加后不用重选
    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/PiyiInbox", directoryHint: .isDirectory)
    private static let drive = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    private static let receivedKey = "phoneReceived"

    /// 把收件箱里还没收的收进资料库，查过重后回话
    typealias Drain = (_ inbox: Inbox, _ heard: @escaping @MainActor (Inbox.Arrival, Receipt) -> Void) -> Void

    /// 这台 Mac 开着 iCloud 云盘。没开时引导提示去打开，打开后回到 App 时接上
    private(set) var available = false
    /// 最近一次从手机收到、并存进资料库的时间：有过就算手机连好了
    private(set) var received: Date?
    /// 这次打开后最近收到的第一样，引导里给人看「收到了什么」
    private(set) var latest: Source?

    private var store: Store?
    private var watcher: DispatchSourceFileSystemObject?
    private var retry: Task<Void, Never>?
    /// 快捷指令把分享的链接和文字存成 .txt，其它文件原样存；读不到的（还没从 iCloud 下载下来）留到下次
    private let inbox = Inbox(folder: PhoneInbox.folder) { file in
        FileExtractor.sources(fromShared: file).map { Inbox.Arrival(file: file, sources: $0) }
    }
    private var drain: Drain = { _, _ in }

    func start(store: Store, drain: @escaping Drain) async {
        self.store = store
        self.drain = drain
        received = try? await store.setting(Self.receivedKey, as: Date.self)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        look()
    }

    /// 云盘开着、但「快捷指令」的文件夹还没同步到这台 Mac 时先不盯，每 10 秒再看一次：
    /// 手机第一次存进东西后文件夹才同步过来，这时人多半正看着引导，不会切走再切回 App
    private func watch() {
        available = FileManager.default.fileExists(atPath: Self.drive.path)
        guard available, FileManager.default.fileExists(atPath: Self.folder.deletingLastPathComponent().path) else {
            if available, retry == nil {
                retry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    self?.retry = nil
                    self?.look()
                }
            }
            return
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.look() } }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        self.watcher = watcher
    }

    private func arrived(_ first: Source) {
        latest = first
        received = .now
        let store = store
        Task { try? await store?.setSetting(Self.receivedKey, Date.now) }
    }

    private func look() {
        if watcher == nil { watch() }
        guard watcher != nil else { return }
        drain(inbox) { [weak self] arrival, receipt in
            if receipt.kept, let first = arrival.sources.first { self?.arrived(first) }
        }
    }
}
