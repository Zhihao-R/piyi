import SwiftUI
import Library
import Intelligence

/// 设置：按服务方填密钥、下载本机模型、浏览器扩展、手机
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(model.cloud, id: \.name) { KeyField(provider: $0, model: model) }
            } header: {
                Text("服务方")
            } footer: {
                Text("标题、描述、标签和总结交给云端生成。密钥存在本机的一个文件里，只有你的账户能读。").foregroundStyle(.secondary)
            }
            Section {
                LocalModelRow(model: model)
            } header: {
                Text("本机模型")
            } footer: {
                Text("向量在本机算：离线也能搜。").foregroundStyle(.secondary)
            }
            Section {
                ExtensionRow(model: model)
            } header: {
                Text("浏览器扩展")
            } footer: {
                Text("在网页上右键「收进拼贴」：点在图上收这张图，选中了文字收这段话，其余收整页。要登录、靠脚本加载的网页，也交给它在你的浏览器里后台打开。\n别的 App 里：复制后按 ⌃⌥C，或者选中文字、文件后右键「服务」→「收进拼贴」。").foregroundStyle(.secondary)
            }
            Section {
                PhoneRow(inbox: model.phoneInbox)
            } header: {
                Text("手机")
            } footer: {
                Text(OnboardingStep.phone.detail).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一个服务方的密钥：填了显示「已填」，被拒了提示换一把，可以换或删
struct KeyField: View {
    let provider: any Keyed
    let model: AppModel
    @State private var key = ""

    var body: some View {
        HStack {
            SecureField("\(provider.name) 密钥", text: $key, prompt: Text(prompt))
                .onSubmit(save)
            Button("保存", action: save).disabled(key.isEmpty)
            if state != .missing, key.isEmpty { Button("删除") { model.setKey("", for: provider) } }
        }
    }

    private var state: KeyState { model.keyStates[provider.name] ?? .missing }

    private var prompt: String {
        switch state {
        case .missing: String(localized: "填入密钥")
        case .rejected: String(localized: "密钥被拒绝，请换一把")
        case .ready: String(localized: "已填，输入新的可以替换")
        }
    }

    private func save() {
        model.setKey(key, for: provider)
        key = ""
    }
}

/// 本机向量模型：下载、进度、已就绪
struct LocalModelRow: View {
    let model: AppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalModel.name)
                Text(model.localModelReady ? "已下载" : "约 \(LocalModel.size / 1_000_000) MB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = model.modelDownload {
                ProgressView(value: progress).frame(width: 120)
            } else if !model.localModelReady {
                Button("下载") { model.downloadLocalModel() }
            }
        }
    }
}

/// 窗口底部一行，有事才出现：正在处理几张、等待密钥、失败几张（带重试）、离线。平时画布一直铺到窗口底
struct StatusBar: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let c = model.counts
        if c.processing > 0 || c.waitingKey > 0 || c.failed > 0 || !model.online {
            HStack(spacing: 14) {
                if c.processing > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在处理 \(c.processing) 张")
                    }
                }
                if c.waitingKey > 0 {
                    Button(model.keyRejected ? "密钥被拒绝，\(c.waitingKey) 张等新密钥" : "\(c.waitingKey) 张等待密钥") { openSettings() }.buttonStyle(.link)
                }
                if c.failed > 0 {
                    HStack(spacing: 4) {
                        Text("\(c.failed) 张理解失败")
                        Button("重试") { model.retryFailed() }.buttonStyle(.link)
                    }
                }
                Spacer()
                if !model.online { Label("离线", systemImage: "wifi.slash") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
        }
    }
}
