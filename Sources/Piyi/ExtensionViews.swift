import SwiftUI
import Tokens

/// 设置里的一行：扩展连没连上，没连上时给安装指引
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

/// 连上了是一个绿点，等着时是一个慢慢呼吸的灰点
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

/// 安装扩展的两步，连上后换成一句说明。引导和设置共用
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
                    Text("在浏览器里点工具栏上的片羽图标，就把正在看的网页收进来。图标没出现的话，点工具栏上的拼图图标，把片羽固定上去。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    GuideStep(number: 1, text: String(localized: "在浏览器里打开扩展页，打开「开发者模式」（Edge 里叫「开发人员模式」）")) {
                        OpenPageButton(browserExtension: browserExtension)
                    }
                    GuideStep(number: 2, text: String(localized: "把下面这个文件夹拖进扩展页。浏览器有多个个人资料的，拖进常用的那个")) {
                        FolderTile(browserExtension: browserExtension)
                    }
                    HStack(spacing: 8) {
                        StatusDot(on: browserExtension.status.isConnected)
                        Text("装好后这里会自动变成已连上").font(.callout).foregroundStyle(.secondary)
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

/// 打开扩展页：只装了一个浏览器就一个按钮，装了几个就让你选
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

/// 扩展文件夹：可以直接拖走，也可以在访达里找到它
private struct FolderTile: View {
    let browserExtension: BrowserExtension
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: browserExtension.folder.path))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("片羽扩展").font(.callout.weight(.medium))
                Text("也可以在扩展页点「加载已解压的扩展程序」选它").font(.caption).foregroundStyle(.secondary)
            }
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
