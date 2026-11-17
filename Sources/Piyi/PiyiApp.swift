import SwiftUI
import Library

@main
struct PiyiApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        Window("片羽", id: "main") {
            Shell(model: model)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    app.model = model
                    await model.start(quickCollect: app.quickCollect)
                }
        }
        // Open the main window on every launch: if the window was closed at last quit, the system won't reopen it by default, and nothing would start the library and understanding queue
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建画板") { model.newBoard() }.keyboardShortcut("n")
            }
            CommandMenu("画布") {
                // Read it so the menu refreshes when selection and crop state change
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

    /// The shortcut and the Services menu must be caught before the window appears
    @MainActor func applicationWillFinishLaunching(_ notification: Notification) { quickCollect.listen() }

    /// Save the text card being written before quitting: ⌘Q doesn't make the text field lose focus, and without waiting, half-written text would be lost
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let saving = model?.canvas?.finishEditing() else { return .terminateNow }
        Task {
            await saving.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
