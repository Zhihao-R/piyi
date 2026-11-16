import SwiftUI
import Library
import Intelligence

// 云端怎么接是这台 Mac 上的偏好，记在 UserDefaults。模型名、地址各家分开记：换回去时还在

extension CloudSetup {
    private static var defaults: UserDefaults { .standard }

    /// 上次选的那家
    static var saved: CloudSetup {
        saved(for: defaults.string(forKey: "cloudVendor").flatMap(Vendor.init) ?? .openRouter)
    }

    static func saved(for vendor: Vendor) -> CloudSetup {
        CloudSetup(vendor: vendor, address: defaults.string(forKey: "cloudAddress.\(vendor.rawValue)") ?? "",
                   model: defaults.string(forKey: "cloudModel.\(vendor.rawValue)") ?? "",
                   judgeModel: defaults.string(forKey: "cloudJudgeModel.\(vendor.rawValue)") ?? "",
                   thinking: defaults.bool(forKey: "cloudThinking"))
    }

    func save() {
        Self.defaults.set(vendor.rawValue, forKey: "cloudVendor")
        Self.defaults.set(address, forKey: "cloudAddress.\(vendor.rawValue)")
        Self.defaults.set(model, forKey: "cloudModel.\(vendor.rawValue)")
        Self.defaults.set(judgeModel, forKey: "cloudJudgeModel.\(vendor.rawValue)")
        Self.defaults.set(thinking, forKey: "cloudThinking")
    }
}

/// 选服务商、填这家的密钥；这家没有默认模型或地址时，把必填的也列出来。设置和引导共用
struct CloudAccess: View {
    let model: AppModel
    /// 引导里没有每行左边的标题，提示语要自己说明填什么
    var labeled = true

    var body: some View {
        let vendor = model.cloudSetup.vendor
        Picker("服务商", selection: Binding(get: { vendor }, set: { model.chooseVendor($0) })) {
            ForEach(Vendor.groups, id: \.self) { group in
                if group != Vendor.groups[0] { Divider() }
                ForEach(group) { Text(displayed($0.name)) }
            }
        }
        if vendor == .custom {
            CloudField(title: String(localized: "接口地址"), prompt: (labeled ? "" : String(localized: "接口地址，如 ")) + "https://api.example.com/v1", path: \.address, vendor: vendor, model: model)
        }
        ForEach(model.cloud, id: \.name) { KeyField(provider: $0, model: model, labeled: labeled) }
        if labeled || vendor.defaultModel == nil {
            CloudField(title: String(localized: "模型"), prompt: vendor.defaultModel ?? (labeled ? String(localized: "必填") : String(localized: "模型名，必填")), path: \.model, vendor: vendor, model: model)
        }
    }
}

/// 云端设置里的一项文字：回车、移开焦点或关掉设置时生效
struct CloudField: View {
    let title: String
    let prompt: String
    let path: WritableKeyPath<CloudSetup, String>
    /// 这一项属于哪家：换了服务商后，旧的那一项消失时不能把字写到新的那家上
    let vendor: Vendor
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onAppear { text = model.cloudSetup[keyPath: path] }
            .onDisappear(perform: save)
            // 带上是哪一项：设置的 Form 按行认身份，几项都只用 vendor 会被当成同一行，显示成重复的
            .id("\(vendor.rawValue).\(title)")
    }

    private func save() {
        guard model.cloudSetup.vendor == vendor else { return }
        var setup = model.cloudSetup
        setup[keyPath: path] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setCloud(setup)
    }
}
