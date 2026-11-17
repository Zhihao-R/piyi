import SwiftUI
import Library
import Intelligence

// How the cloud is connected is a preference of this Mac, stored in UserDefaults. Model names and addresses are stored per provider: still there when switching back

extension CloudSetup {
    private static var defaults: UserDefaults { .standard }

    /// The provider chosen last time
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

/// Choose a provider and enter its key; if it has no default model or address, list the required ones too. Shared by settings and onboarding
struct CloudAccess: View {
    let model: AppModel
    /// Onboarding has no title to the left of each row, so the placeholder has to say what to enter
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
        // Those with a default model go into Advanced; those without are required and stay here
        if vendor.defaultModel == nil {
            CloudField(title: String(localized: "模型"), prompt: labeled ? String(localized: "必填") : String(localized: "模型名，必填"), path: \.model, vendor: vendor, model: model)
        }
    }
}

/// A text item in the cloud settings: takes effect on Return, losing focus, or closing settings
struct CloudField: View {
    let title: String
    let prompt: String
    let path: WritableKeyPath<CloudSetup, String>
    /// Which provider this item belongs to: after switching providers, when the old item disappears its text must not be written to the new provider
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
            // Include which item: the settings Form identifies rows by identity; using only vendor for several items makes them count as the same row and show up as duplicates
            .id("\(vendor.rawValue).\(title)")
    }

    private func save() {
        guard model.cloudSetup.vendor == vendor else { return }
        var setup = model.cloudSetup
        setup[keyPath: path] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setCloud(setup)
    }
}

// MARK: Advanced

/// Advanced cloud settings: which model, the judging model, deep thinking, and writing instructions for the AI. Rarely needed; reached via "Advanced" in settings
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
                    // Judging can use a separate faster model. OpenRouter defaults to Jev, made for judging; other providers default to the same model as above, a few have a different recommendation
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
                    Text(String(localized: "判断模型用于解析搜索语句和排序结果，建议选用响应较快的模型。")
                         + (vendor.canSetThinking ? String(localized: "开启深入思考后，回答更为细致，耗时也更长。") : ""))
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Writing.Part.allCases, id: \.self) { StyleRow(part: $0) }
                } header: {
                    Text("写作要求")
                } footer: {
                    Text("此处仅调整写作风格与侧重。输出格式、出处标注和语言由片羽统一处理，不受此处设置影响。").foregroundStyle(.secondary)
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

/// Writing instructions for one thing: collapsed normally, expand to edit; edits take effect immediately, clearing or restoring default goes back to the default
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

// Writing instructions are also a preference of this Mac, stored in UserDefaults; only edited ones are stored, unedited ones use the default for the interface language
extension Writing.Part {
    private var key: String { "style.\(rawValue)" }

    var title: String {
        switch self {
        case .card: String(localized: "标题、描述和标签")
        case .summary: String(localized: "要点")
        case .discussion: String(localized: "讨论")
        case .answer: String(localized: "搜索提问")
        case .draw: String(localized: "styles.draw", defaultValue: "随机抽卡")
        case .inspiration: String(localized: "灵感")
        }
    }

    /// Things to know before editing
    var note: String? {
        switch self {
        case .card: String(localized: "仅对此后整理的卡片生效；标签最多保留 10 个。")
        case .summary: String(localized: "仅对此后整理的卡片生效；要点最多保留 5 条。")
        case .inspiration: String(localized: "每组灵感均需核对其内容能否在卡片中得到印证；要求越宽泛，生成越慢、数量越少。")
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
