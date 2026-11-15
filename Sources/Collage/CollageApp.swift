import SwiftUI
import Library

@main
struct CollageApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        Window("拼贴", id: "main") {
            Shell(model: model)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    app.model = model
                    await model.start(quickCollect: app.quickCollect)
                }
        }
        // 每次启动都打开主窗口：上次关着窗口退出时，系统默认不再打开它，资料库和理解队列也就没人启动
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建画板") { model.newBoard() }.keyboardShortcut("n")
            }
            CommandMenu("画布") {
                // 读一下，选中和裁剪状态变了菜单就刷新
                let _ = model.canvasTick
                Button("搜索") { model.searchFocus += 1 }.keyboardShortcut("f")
                Button("回到全景") { model.canvas?.fitAll(animated: true) }.keyboardShortcut("0")
                Button("整理成行") { model.canvas?.arrangeRows() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.canvas?.isEditable != true)
                Button("裁剪") { model.canvas?.beginCrop() }
                    .keyboardShortcut("k")
                    .disabled(model.canvas?.canCrop != true)
                Button("放大查看") { openSelected() }
                    .keyboardShortcut("y")
                    .disabled(model.canvas?.selection.count != 1)
                Divider()
                Button("后退") { model.back() }
                    .keyboardShortcut("[")
                    .disabled(model.history.isEmpty)
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }

    private func openSelected() {
        guard let canvas = model.canvas, let item = canvas.selectedItems.first else { return }
        model.canvas(canvas, open: item)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    @MainActor let quickCollect = QuickCollect()

    /// 快捷键和「服务」菜单在窗口出来之前就要接住
    @MainActor func applicationWillFinishLaunching(_ notification: Notification) { quickCollect.listen() }

    /// 退出前先把正在写的文字卡存好：⌘Q 不会让文本框失去焦点，不等它的话写到一半的字就丢了
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let saving = model?.canvas?.finishEditing() else { return .terminateNow }
        Task {
            await saving.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
