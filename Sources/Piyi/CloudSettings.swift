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
        // 有默认模型的放进详细设置；没有的必填，留在这里
        if vendor.defaultModel == nil {
            CloudField(title: String(localized: "模型"), prompt: labeled ? String(localized: "必填") : String(localized: "模型名，必填"), path: \.model, vendor: vendor, model: model)
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

// MARK: 详细设置

/// 云端的详细设置：用哪个模型、判断模型、深入思考，和给 AI 的写法要求。平时用不着，从设置里「详细设置」点进来
struct CloudDetails: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let vendor = model.cloudSetup.vendor
        VStack(spacing: 0) {
            Form {
                Section {
                    if let standard = vendor.defaultModel {
                        CloudField(title: String(localized: "模型"), prompt: standard, path: \.model, vendor: vendor, model: model)
                    }
                    if model.cloudModelUnknown {
                        Text("OpenRouter 上未找到该模型").font(.caption).foregroundStyle(.secondary)
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
                    Text("模型")
                } footer: {
                    Text(String(localized: "判断模型用于理解搜索语句、排序结果，宜选较快的模型。")
                         + (vendor.canSetThinking ? String(localized: "深入思考时回答更细致，也更慢。") : ""))
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Writing.Part.allCases, id: \.self) { StyleRow(part: $0) }
                } header: {
                    Text("给 AI 的要求")
                } footer: {
                    Text("这里只管写法和侧重。输出格式、出处标注和用哪种语言由片羽决定，不受这里影响。").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 600)
    }
}

/// 一样东西的写法要求：平时收着，点开改；改完即生效，清空或恢复默认就回到默认
struct StyleRow: View {
    let part: Writing.Part
    @State private var text = ""

    var body: some View {
        DisclosureGroup {
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 110)
            HStack(alignment: .firstTextBaseline) {
                if let note = part.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("恢复默认") { text = part.standard }.disabled(text == part.standard)
            }
        } label: {
            HStack {
                Text(part.title)
                Spacer()
                if edited { Text("已修改").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear { text = part.style }
        .onChange(of: text) { part.save(text) }
    }

    private var edited: Bool { part.customized(text) != nil }
}

// 写法要求也是这台 Mac 上的偏好，记在 UserDefaults；只记改过的，没改的跟着界面语言用默认
extension Writing.Part {
    private var key: String { "style.\(rawValue)" }

    var title: String {
        switch self {
        case .card: String(localized: "标题、描述和标签")
        case .summary: String(localized: "要点")
        case .discussion: String(localized: "讨论")
        case .answer: String(localized: "搜索框里提问")
        case .draw: String(localized: "抽一张")
        case .inspiration: String(localized: "灵感")
        }
    }

    /// 改之前要知道的事
    var note: String? {
        switch self {
        case .card: String(localized: "只影响之后整理的卡片，标签最多保留 10 个。")
        case .summary: String(localized: "只影响之后整理的卡片，最多保留 5 条。")
        case .inspiration: String(localized: "每组灵感都要核对说的在卡里看得到，要求越发散，出得越慢、越少。")
        default: nil
        }
    }

    func save(_ text: String) {
        Writing.setStyle(text, for: self)
        UserDefaults.standard.set(customized(text), forKey: key)
    }

    static func restoreSaved() {
        for part in allCases { Writing.setStyle(UserDefaults.standard.string(forKey: part.key), for: part) }
    }
}
