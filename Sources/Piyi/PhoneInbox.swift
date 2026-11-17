import AppKit
import Library

/// Phone inbox: PiyiInbox under the Shortcuts folder in iCloud Drive. The "Collect To Piyi" shortcut on the phone saves shared links, text, images and files there,
/// which are collected here once synced to this Mac. Checked when the folder changes and when the App comes to the foreground; when the App isn't open, files stay in iCloud and are collected after launch.
/// Same approach as the local inbox (Library's Inbox): originals are deleted only after the content is saved to the library
@MainActor @Observable
final class PhoneInbox {
    /// Share link of the "Collect To Piyi" shortcut: made into a QR code in onboarding for the phone to scan
    static let shortcut = URL(string: "https://www.icloud.com/shortcuts/5b5e848e90ed40ae9e1f65116217dec5")!
    /// Placed in the Shortcuts app's own folder: Shortcuts records this location as "its own folder", not tied to an account, so people who add a shared copy don't have to pick it again
    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/PiyiInbox", directoryHint: .isDirectory)
    private static let drive = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    private static let receivedKey = "phoneReceived"

    /// Collect what's not yet collected in the inbox into the library, reply after deduplication
    typealias Drain = (_ inbox: Inbox, _ heard: @escaping @MainActor (Inbox.Arrival, Receipt) -> Void) -> Void

    /// This Mac has iCloud Drive on. If not, onboarding asks you to turn it on and picks up when you return to the App
    private(set) var available = false
    /// Last time something from the phone was received and saved to the library: once it has happened, the phone counts as connected
    private(set) var received: Date?
    /// The first thing received since this launch, shown in onboarding as "what was received"
    private(set) var latest: Source?

    private var store: Store?
    private var watcher: DispatchSourceFileSystemObject?
    private var retry: Task<Void, Never>?
    /// Shortcuts saves shared links and text as .txt and other files as is; unreadable ones (not yet downloaded from iCloud) wait until next time
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

    /// When iCloud Drive is on but the Shortcuts folder hasn't synced to this Mac yet, don't watch it yet; check again every 10 seconds:
    /// the folder only syncs after the phone first saves something, and the person is probably watching onboarding then, not switching away and back to the App
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
