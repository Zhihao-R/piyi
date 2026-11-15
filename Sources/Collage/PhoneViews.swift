import SwiftUI
import CoreImage.CIFilterBuiltins
import Library
import Tokens

/// 设置里的一行：从手机收到过没有，没收到过时给设置指引
struct PhoneRow: View {
    let inbox: PhoneInbox
    @State private var guiding = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(on: inbox.received != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text("收集拼贴")
                Group {
                    if let date = inbox.received { Text("上次接收：\(date.formatted(.relative(presentation: .named)))") } else { Text("尚未接收") }
                }
                .font(.caption).foregroundStyle(.secondary)
                .contentTransition(.opacity)
            }
            Spacer()
            if inbox.received == nil { Button("设置指引…") { guiding = true } }
        }
        .animation(.fade, value: inbox.received)
        .sheet(isPresented: $guiding) {
            GuideSheet(step: .phone) { guiding = false } content: { PhoneGuide(inbox: inbox) }
        }
    }
}

/// 扫码添加快捷指令、分享一张照片，收到后换成「已收到」。引导和设置共用。
/// 拼贴看不到手机上装了什么，收到第一样东西才算连好
struct PhoneGuide: View {
    let inbox: PhoneInbox

    var body: some View {
        Group {
            if !inbox.available {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("此 Mac 未开启 iCloud 云盘").font(.headline).foregroundStyle(Palette.warning.color)
                        Text("请在「系统设置 › Apple 账户 › iCloud」中开启。").font(.callout).foregroundStyle(.secondary)
                    }
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
                    }
                }
                .transition(.opacity)
            } else if inbox.received != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Label("已收到", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .symbolRenderingMode(.multicolor)
                    if let latest = inbox.latest {
                        HStack(spacing: 12) {
                            Image(systemName: latest.symbol).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(latest.label).lineLimit(1).truncationMode(.middle)
                                Text("已存入资料库「未归类」").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    GuideStep(number: 1, text: String(localized: "用 iPhone 相机扫码，添加快捷指令")) {
                        HStack(spacing: 16) {
                            QRCode(url: PhoneInbox.shortcut)
                            Button("拷贝链接") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(PhoneInbox.shortcut.absoluteString, forType: .string)
                            }
                            .buttonStyle(.link).font(.callout)
                        }
                    }
                    GuideStep(number: 2, text: String(localized: "在相册中分享一张照片，选择「收集拼贴」")) { EmptyView() }
                    HStack(spacing: 8) {
                        StatusDot(on: false)
                        Text("等待接收").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: Motion.place.response, dampingFraction: Motion.place.damping), value: inbox.available)
        .animation(.spring(response: Motion.place.response, dampingFraction: Motion.place.damping), value: inbox.received)
    }
}

/// 白底黑码，放大时不糊
private struct QRCode: View {
    let url: URL

    var body: some View {
        Group {
            if let image = Self.image(url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable()
            }
        }
        .frame(width: 96, height: 96)
        .padding(8)
        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: output.extent.size)
    }
}

private extension Source {
    var symbol: String {
        switch self {
        case .file(let url):
            switch FileExtractor.kind(of: url) {
            case .image: "photo"
            case .video: "film"
            case .audio: "waveform"
            default: "doc"
            }
        case .url: "link"
        case .text: "text.alignleft"
        default: "tray"
        }
    }

    var label: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .url(let url): url.host() ?? url.absoluteString
        case .text(let text): String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        default: String(localized: "一项内容")
        }
    }
}
