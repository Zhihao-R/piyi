import SwiftUI
import Tokens

/// A row in settings: whether the extension is connected, with installation instructions when not
struct ExtensionRow: View {
    let model: AppModel
    @State private var guiding = false

    var body: some View {
        let status = model.browserExtension.status
        HStack(spacing: 10) {
            StatusDot(on: status.isConnected)
            VStack(alignment: .leading, spacing: 2) {
                Text("片羽扩展")
                Text(status.summary).font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            if !status.isConnected { Button("安装指引…") { guiding = true } }
        }
        .animation(.fade, value: status)
        .sheet(isPresented: $guiding) {
            GuideSheet(step: .browser) { guiding = false } content: { ExtensionGuide(model: model) }
        }
    }
}

extension BrowserExtension.Status {
    var isConnected: Bool { if case .connected = self { true } else { false } }

    var summary: String {
        switch self {
        case .connected(let names): String(localized: "已连接 \(names.formatted(.list(type: .and)))")
        case .idle: String(localized: "未连接，打开浏览器后自动连接")
        case .absent: String(localized: "未安装")
        }
    }
}

/// A green dot when connected, a slowly breathing gray dot while waiting
struct StatusDot: View {
    let on: Bool
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(on ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            .frame(width: 7, height: 7)
            .opacity(on || !breathing ? 1 : 0.35)
            .animation(on ? .default : .easeInOut(duration: Motion.wait / 2).repeatForever(), value: breathing)
            .onAppear { breathing = true }
    }
}

/// The two steps to install the extension, replaced by a sentence once connected. Shared by onboarding and settings
struct ExtensionGuide: View {
    let model: AppModel
    private var browserExtension: BrowserExtension { model.browserExtension }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if case .connected(let names) = browserExtension.status {
                VStack(alignment: .leading, spacing: 10) {
                    Label("已连上 \(names.formatted(.list(type: .and)))", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .symbolRenderingMode(.multicolor)
                        .symbolEffect(.bounce, value: names)
                    Text("若工具栏上没有片羽图标，请点击拼图图标将其固定。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    GuideStep(number: 1, text: String(localized: "打开浏览器的扩展页，开启「开发者模式」")) {
                        OpenPageButton(browserExtension: browserExtension)
                    }
                    GuideStep(number: 2, text: String(localized: "将下方文件夹拖入扩展页")) {
                        FolderTile(browserExtension: browserExtension)
                    }
                    HStack(spacing: 8) {
                        StatusDot(on: browserExtension.status.isConnected)
                        Text("安装完成后将自动连接").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: Motion.place.response, dampingFraction: Motion.place.damping), value: browserExtension.status)
    }
}

struct GuideStep<Content: View>: View {
    let number: Int
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                content
            }
        }
    }
}

/// Open the extensions page: one button if only one browser is installed, a choice if several
private struct OpenPageButton: View {
    let browserExtension: BrowserExtension

    var body: some View {
        let browsers = browserExtension.installedBrowsers
        if browsers.count > 1 {
            SwiftUI.Menu("打开扩展页") {
                ForEach(browsers) { browser in Button(browser.name) { browserExtension.openExtensionsPage(in: browser) } }
            }
            .fixedSize()
        } else if let browser = browsers.first {
            Button("打开 \(browser.name) 的扩展页") { browserExtension.openExtensionsPage(in: browser) }
        } else {
            Text("没找到 Chrome、Edge 或 Arc").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Extension folder: can be dragged away directly, or found in Finder
private struct FolderTile: View {
    let browserExtension: BrowserExtension
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: browserExtension.folder.path))
                .resizable()
                .frame(width: 36, height: 36)
            Text("片羽扩展").font(.callout.weight(.medium))
            Spacer(minLength: 12)
            Button("在访达中显示") { browserExtension.revealFolder() }.buttonStyle(.link).font(.caption)
        }
        .padding(12)
        .background(.quaternary.opacity(hovering ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.spring(response: Motion.lift.response, dampingFraction: Motion.lift.damping), value: hovering)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: browserExtension.folder as NSURL) }
        .help("拖进浏览器的扩展页")
    }
}
