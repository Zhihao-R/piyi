import SwiftUI
import Library
import Intelligence

/// 设置：云端服务商和密钥、下载本机模型、浏览器扩展、手机
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        let vendor = model.cloudSetup.vendor
        Form {
            Section {
                CloudAccess(model: model)
                if model.cloudModelUnknown {
                    Text("OpenRouter 上未找到该模型").font(.caption).foregroundStyle(.secondary)
                } else if let failure = model.cloudFailure {
                    Text("上次请求未成功。\(failure)").font(.caption).foregroundStyle(.secondary)
                }
                // 判断可以另用一个更快的模型。OpenRouter 默认用专做判断的 Jev；别家默认和上面的模型相同，个别有另外推荐的
                CloudField(title: String(localized: "判断模型"), prompt: vendor == .openRouter ? String(localized: "Jev（推荐）") : vendor.defaultJudgeModel ?? String(localized: "与上方模型相同"),
                           path: \.judgeModel, vendor: vendor, model: model)
                if vendor.canSetThinking {
                    Toggle("讨论时深入思考", isOn: Binding(get: { model.cloudSetup.thinking }, set: { on in
                        var setup = model.cloudSetup
                        setup.thinking = on
                        model.setCloud(setup)
                    }))
                }
            } header: {
                Text("云端模型")
            } footer: {
                Text(String(localized: "用于生成标题、描述、标签和总结，以及搜索和讨论。判断模型用于理解搜索语句、排序结果，宜选较快的模型。")
                     + (vendor.canSetThinking ? String(localized: "深入思考时回答更细致，也更慢。") : "") + String(localized: "密钥仅保存在本机。")
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
                Text("在 iPhone 上分享到「收集片羽」。").foregroundStyle(.secondary)
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
    /// 引导里没有每行左边的标题，提示语要自己说明填什么
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
