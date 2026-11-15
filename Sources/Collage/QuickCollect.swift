import AppKit
import Carbon.HIToolbox
import SwiftUI
import Library
import Tokens

/// 不切到拼贴也能收：任何 App 里按 ⌃⌥C 收剪贴板里新复制的东西；选中文字、文件后右键「服务」→「收进拼贴」收选中的。
/// 和手机、浏览器收的一样先存进收件箱、只进资料库，等自动分拣。拼贴在后台时，屏幕右上角弹一句提示，不把窗口拉到前面
@MainActor
final class QuickCollect: NSObject {
    /// 叫收集去看本机收件箱。资料库准备好之前是 nil：这时收到的在收件箱里等着
    private var look: (() -> Void)?
    /// 存进了收件箱、还没回话的几次
    private var pending: Set<String> = []
    private var tell: (String) -> Void = { _ in }
    private var hotKey: EventHotKeyRef?
    /// 上次按快捷键时剪贴板的变化计数：没再复制过就不重复收
    private var lastTaken: Int?
    private let toast = Toast()

    /// App 一启动就接：从「服务」菜单把没开的拼贴叫起来时，请求马上就到，等不到资料库打开
    func listen() {
        NSApp.servicesProvider = self
        // 系统级快捷键：不用辅助功能权限，别的 App 在前台也收得到
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            MainActor.assumeIsolated { Unmanaged<QuickCollect>.fromOpaque(me!).takeUnretainedValue().takeClipboard() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x434C_4C47), id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    /// 资料库准备好了：收件箱里等着的收进去。tell 在拼贴是前台时用窗口里的提示
    func start(look: @escaping () -> Void, tell: @escaping (String) -> Void) {
        self.look = look
        self.tell = tell
        look()
        if hotKey == nil { tell("⌃⌥C 被别的 App 占用了，按它收不了东西") }
    }

    /// 「服务」菜单里的「收进拼贴」：名字和 Info.plist 里 NSServices 的 NSMessage 对应
    @objc func collect(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        take(Collector.sources(in: pasteboard), empty: "选中的内容收不了")
    }

    /// 快捷键收的是剪贴板，不一定是刚复制的：密码管理器标了隐藏、临时的不收，上次收过之后没再复制过的不收
    private func takeClipboard() {
        let clipboard = NSPasteboard.general
        let types = Set(clipboard.types ?? [])
        if !types.isDisjoint(with: [.init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")]) {
            return say("剪贴板里是密码之类的内容，没收")
        }
        guard clipboard.changeCount != lastTaken else { return say("剪贴板没有新东西") }
        let sources = Collector.sources(in: clipboard)
        if !sources.isEmpty { lastTaken = clipboard.changeCount }
        take(sources, empty: "剪贴板里没有能收的东西")
    }

    /// 先存进收件箱；等收集查过重（heard）才说「收下了」
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
                say("没收下：\(error.localizedDescription)")
            }
        }
    }

    /// 收集查过重了：是这里存的就说一声（一样都没存好时不响）。交回是不是说了
    func heard(_ id: String?, _ receipt: Receipt) -> Bool {
        guard let id, pending.remove(id) != nil else { return false }
        say(receipt.text, collected: receipt.kept)
        return true
    }

    /// 收下了响一声：眼睛不在屏幕角上也知道；没收的不响
    private func say(_ text: String, collected: Bool = false) {
        if collected { NSSound(named: "Pop")?.play() }
        if NSApp.isActive { tell(text) } else { toast.show(text, collected: collected) }
    }
}

/// 屏幕右上角的一句提示：和窗口里的提示同一种玻璃胶囊，但要在整个桌面上看得见，所以字大一号、带图标。
/// 点不到、不抢焦点，停一会儿淡出
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
