import AppKit
import Carbon.HIToolbox
import SwiftUI
import Library
import Tokens

/// Collect without switching to Piyi: press ⌃⌥C in any App to collect what was newly copied to the clipboard; select text or files and right-click Services → "Collect to Piyi" to collect the selection.
/// Like phone and browser collections, saved to the inbox first, library only, waiting for automatic sorting. When Piyi is in the background, a hint pops up at the top right of the screen without bringing the window forward
@MainActor
final class QuickCollect: NSObject {
    /// Asks collection to check the local inbox. nil before the library is ready: what arrives then waits in the inbox
    private var look: (() -> Void)?
    /// Collections saved to the inbox and not yet replied to
    private var pending: Set<String> = []
    private var tell: (String) -> Void = { _ in }
    private var hotKey: EventHotKeyRef?
    /// The clipboard's change count at the last shortcut press: if nothing was copied since, don't collect again
    private var lastTaken: Int?
    private let toast = Toast()

    /// Catch it as soon as the App launches: when the Services menu wakes Piyi when it's not running, the request arrives immediately, before the library opens
    func listen() {
        NSApp.servicesProvider = self
        // System-wide hotkey: no Accessibility permission needed, works while another App is in front
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            MainActor.assumeIsolated { Unmanaged<QuickCollect>.fromOpaque(me!).takeUnretainedValue().takeClipboard() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x5049_5949), id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    /// The library is ready: collect what's waiting in the inbox. tell uses the in-window hint when Piyi is in front
    func start(look: @escaping () -> Void, tell: @escaping (String) -> Void) {
        self.look = look
        self.tell = tell
        look()
        if hotKey == nil { tell(String(localized: "⌃⌥C 被别的 App 占用了，按它收不了东西")) }
    }

    /// "Collect to Piyi" in the Services menu: the name matches the NSMessage of NSServices in Info.plist
    @objc func collect(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        take(Collector.sources(in: pasteboard), empty: String(localized: "选中的内容收不了"))
    }

    /// The shortcut collects the clipboard, which isn't necessarily freshly copied: skip items password managers mark as concealed or transient, and skip if nothing was copied since the last collection
    private func takeClipboard() {
        let clipboard = NSPasteboard.general
        let types = Set(clipboard.types ?? [])
        if !types.isDisjoint(with: [.init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")]) {
            return say(String(localized: "剪贴板里是密码之类的内容，没收"))
        }
        guard clipboard.changeCount != lastTaken else { return say(String(localized: "剪贴板没有新东西")) }
        let sources = Collector.sources(in: clipboard)
        if !sources.isEmpty { lastTaken = clipboard.changeCount }
        take(sources, empty: String(localized: "剪贴板里没有能收的东西"))
    }

    /// Save to the inbox first; say "collected" only after collection has deduplicated it (heard)
    private func take(_ sources: [Source], empty: String) {
        guard !sources.isEmpty else { return say(empty) }
        let id = UUID().uuidString
        pending.insert(id)
        Task {
            do {
                try await Inbox.local.put(sources, id: id)
                look?()
            } catch {
                pending.remove(id)
                say(String(localized: "没收下：\(error.localizedDescription)"))
            }
        }
    }

    /// Collection has deduplicated: if it was saved here, say so (no sound when nothing was saved). Returns whether it spoke
    func heard(_ id: String?, _ receipt: Receipt) -> Bool {
        guard let id, pending.remove(id) != nil else { return false }
        say(receipt.text, collected: receipt.kept)
        return true
    }

    /// A sound when collected: you know even if your eyes aren't on the screen corner; no sound if nothing was collected
    private func say(_ text: String, collected: Bool = false) {
        if collected { NSSound(named: "Pop")?.play() }
        if NSApp.isActive { tell(text) } else { toast.show(text, collected: collected) }
    }
}

/// A hint at the top right of the screen: the same glass capsule as the in-window hint, but visible over the whole desktop, so the text is one size larger with an icon.
/// Not clickable, doesn't steal focus, fades out after a moment
@MainActor
private final class Toast {
    private var panel: NSPanel?
    private var shown = UUID()

    func show(_ text: String, collected: Bool) {
        let panel = panel ?? make()
        self.panel = panel
        let label = Label(text, systemImage: collected ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.title3.weight(.medium))
            .fixedSize()
        let view = NSHostingView(rootView: label.noticeStyle(prominent: true))
        panel.contentView = view
        panel.setContentSize(view.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width, y: screen.maxY))
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = Motion.fade; panel.animator().alphaValue = 1 }
        let mine = UUID()
        shown = mine
        Task {
            try? await Task.sleep(for: .seconds(Motion.notice))
            guard shown == mine else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = Motion.fade; panel.animator().alphaValue = 0 }
            if shown == mine { panel.orderOut(nil) }
        }
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0
        return panel
    }
}
