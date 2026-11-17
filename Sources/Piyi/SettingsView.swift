import SwiftUI
import Library
import Intelligence

/// Settings: language, cloud provider and key (model and writing instructions are in Advanced), local model download, browser extension, phone
struct SettingsView: View {
    let model: AppModel

    @State private var showingDetails = false

    var body: some View {
        Form {
            Section {
                LanguagePicker()
            } footer: {
                Text("界面、AI 生成的卡片内容和灵感使用此语言；讨论与提问使用你输入时所用的语言。重新打开片羽后生效。").foregroundStyle(.secondary)
            }
            Section {
                CloudAccess(model: model)
                if model.cloudModelUnknown {
                    Text("OpenRouter 上未找到该模型，可在「详细设置」中更换").font(.caption).foregroundStyle(.secondary)
                } else if let failure = model.cloudFailure {
                    Text("上次请求未成功。\(failure)").font(.caption).foregroundStyle(.secondary)
                }
                Button { showingDetails = true } label: {
                    HStack {
                        Text("详细设置")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("云端模型")
            } footer: {
                Text(String(localized: "用于生成标题、描述、标签和要点，并支持搜索与讨论。密钥仅保存在本机。")
                     + (model.sortingUnavailable.map { String(localized: "\($0)。") } ?? ""))
                    .foregroundStyle(.secondary)
            }
            Section {
                LocalModelRow(model: model)
            } header: {
                Text("本机模型")
            } footer: {
                Text("用于搜索，离线可用。").foregroundStyle(.secondary)
            }
            Section {
                ExtensionRow(model: model)
            } header: {
                Text("浏览器扩展")
            } footer: {
                Text("在网页上右键「收进片羽」。其他 App 中，复制后按 ⌃⌥C，或右键「服务」›「收进片羽」。").foregroundStyle(.secondary)
            }
            Section {
                PhoneRow(inbox: model.phoneInbox)
            } header: {
                Text("手机")
            } footer: {
                Text("在 iPhone 上分享到「Collect To Piyi」。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingDetails) { CloudDetails(model: model) }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Interface language: follow the system, or set one just for Piyi. Same switch as choosing a per-app language in System Settings (the App's own AppleLanguages),
/// so it takes effect after reopening; titles and descriptions written by AI also follow the interface language (interfaceLanguage)
struct LanguagePicker: View {
    @State private var choice = Self.saved

    var body: some View {
        Picker("语言", selection: $choice) {
            Text("跟随系统").tag("")
            Text(verbatim: "简体中文").tag("zh-Hans")
            Text(verbatim: "English").tag("en")
        }
        .onChange(of: choice) {
            UserDefaults.standard.set(choice.isEmpty ? nil : [choice], forKey: "AppleLanguages")
        }
    }

    /// Only look at what the App itself stored, not the system's: AppleLanguages read via standard is the system language list when not set separately
    private static var saved: String {
        let own = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0)?["AppleLanguages"] as? [String] }
        return own?.first.flatMap { ["zh-Hans", "en"].first(where: $0.hasPrefix) } ?? ""
    }
}

/// A provider's key: shows "Saved" when entered, prompts for another one when rejected, can be replaced or removed
struct KeyField: View {
    let provider: any Keyed
    let model: AppModel
    /// Onboarding has no title to the left of each row, so the placeholder has to say what to enter
    var labeled = true
    @State private var key = ""

    var body: some View {
        HStack {
            SecureField("密钥", text: $key, prompt: Text(prompt))
                .onSubmit(save)
            Button("保存", action: save).disabled(key.isEmpty)
            if state != .missing, key.isEmpty { Button("删除") { model.setKey("", for: provider) } }
        }
    }

    private var state: KeyState { model.keyStates[provider.name] ?? .missing }

    private var prompt: String {
        switch state {
        case .missing: labeled ? String(localized: "未填写") : String(localized: "填入 \(displayed(provider.name)) 的密钥")
        case .rejected: String(localized: "密钥无效，请更换")
        case .ready: String(localized: "已填写")
        }
    }

    private func save() {
        model.setKey(key, for: provider)
        key = ""
    }
}

/// Local embedding model: download, progress, ready
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

/// A row at the bottom of the window, shown only when there's something: how many processing, waiting for a key, how many failed (with retry), offline. Normally the canvas extends to the window bottom
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
                    Button(model.keyRejected ? "密钥无效，\(c.waitingKey) 张等待更换" : model.keyStates.values.contains(.missing) ? "\(c.waitingKey) 张等待密钥" : "\(c.waitingKey) 张等待云端模型设置") { openSettings() }.buttonStyle(.link)
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
