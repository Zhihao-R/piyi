import Foundation

/// Cloud providers. Apart from Claude, which uses its own API (see Claude.swift), all use the same request format (chat/completions);
/// the only differences are the few listed here: address, default model, how thinking is set, whether a few extra parameters are accepted. Adding a provider is adding a case and filling these in.
/// Each provider's format and default model follow the official docs as of 2026-11
public enum Vendor: String, CaseIterable, Sendable, Identifiable {
    /// The key file and preferences are keyed by rawValue, so changing it loses the old ones; OpenRouter keeps the name its key was originally stored under
    case openRouter = "OpenRouter"
    case deepSeek, volcano, bailian, siliconFlow, zhipu, kimi, miniMax, anthropic, gemini, openAI, custom

    public var id: Self { self }

    /// Groups in the Settings dropdown: aggregators, China-based, overseas, custom
    public static let groups: [[Vendor]] = [[.openRouter], [.deepSeek, .volcano, .bailian, .siliconFlow, .zhipu, .kimi, .miniMax],
                                            [.anthropic, .gemini, .openAI], [.custom]]

    /// Request format: mostly chat/completions; Claude uses Anthropic's own messages, and the key goes in a different request header
    enum Wire { case chat, messages }
    var wire: Wire { self == .anthropic ? .messages : .chat }

    /// Name for people
    public var name: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek"
        case .volcano: "火山引擎"
        case .bailian: "阿里云百炼"
        case .siliconFlow: "硅基流动"
        case .zhipu: "智谱 GLM"
        case .kimi: "Kimi"
        case .miniMax: "MiniMax"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        case .custom: "自定义"
        }
    }

    /// API address, followed by /chat/completions (/messages for Claude). Custom ones are entered by the user
    var address: String? {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .volcano: "https://ark.cn-beijing.volces.com/api/v3"
        case .bailian: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: "https://api.moonshot.cn/v1"
        case .miniMax: "https://api.minimax.cn/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openAI: "https://api.openai.com/v1"
        case .custom: nil
        }
    }

    /// Which model to use when none is entered: must see images and call tools, leaning fast and cheap. Custom has none
    public var defaultModel: String? {
        switch self {
        case .openRouter: "deepseek/deepseek-v4.1-flash"
        case .deepSeek: "deepseek-flash"
        case .volcano: "doubao-seed-2-1-pro-260915"
        case .bailian: "qwen3.8-flash"
        case .siliconFlow: "Pro/moonshotai/Kimi-K2.6"
        case .zhipu: "glm-5.3-flash"
        case .kimi: "kimi-k3.1-pro"
        case .miniMax: "MiniMax-M3.1-Flash"
        case .anthropic: "claude-haiku-5-5"
        case .gemini: "gemini-4-hydrogen"
        case .openAI: "gpt-6.1-terra"
        case .custom: nil
        }
    }

    /// Which model to use when no judge model is entered: someone is waiting on judging during search, so take this provider's faster tier; nil means same as defaultModel (the default is already the fast tier,
    /// or no faster image-capable model has been found for this provider yet). OpenRouter uses Jev by default and skips this (see CloudSetup.usesJev)
    public var defaultJudgeModel: String? { self == .openAI ? "gpt-6-luna" : nil }

    /// The request fields that control thinking. Most models think by default, so off must be said explicitly; for the few that can't turn it off, "off" means the lowest thinking tier
    func thinkingFields(on: Bool) -> [String: Any] {
        switch self {
        // OpenRouter's unified form, which it translates for each provider
        case .openRouter: ["reasoning": ["enabled": on]]
        case .deepSeek, .volcano: ["thinking": ["type": on ? "enabled" : "disabled"]]
        case .bailian: ["enable_thinking": on]
        // Only sent when on: the docs don't say whether models that don't accept this parameter would error on it
        case .siliconFlow: on ? ["enable_thinking": true] : [:]
        // These three providers' default models can't turn thinking off, only choose a tier
        case .zhipu, .kimi, .gemini: ["reasoning_effort": on ? "high" : "low"]
        // reasoning_split: put thinking separately instead of mixing it into the answer
        case .miniMax: ["reasoning_effort": on ? "high" : "low", "reasoning_split": true]
        case .openAI: ["reasoning_effort": on ? "high" : "none"]
        // Claude's API is handled separately; custom ones we don't know how to write, so nothing is sent and the model's own default decides
        case .anthropic, .custom: [:]
        }
    }

    /// Whether the thinking switch works for this provider
    public var canSetThinking: Bool { self != .custom }

    /// Whether the model's previous-round thinking is sent back with the discussion record. Only where the docs require it: DeepSeek errors without it when tools are present, Kimi and MiniMax rely on it to keep thinking;
    /// OpenRouter forwards to them. For others sending it back only costs more. Custom: if we've received such content, it speaks this format, so send it back too
    var sendsThoughtsBack: Bool {
        switch self {
        case .openRouter, .deepSeek, .kimi, .miniMax, .custom: true
        default: false
        }
    }

    /// Whether what the provider attaches to tool calls is sent back: Gemini relies on it to keep thinking. Others have no such thing, and when switching providers mid-chat Gemini's must not be sent to them
    var sendsCallExtrasBack: Bool { self == .gemini || self == .custom }

    /// Whether the "answer in JSON" parameter is accepted. Of the rest, either only some models accept it or it conflicts with thinking or images, so it's not sent: the prompt already asks for JSON only
    var jsonMode: Bool { self == .openRouter || self == .deepSeek }

    /// The few fields only OpenRouter has
    var extras: [String: Any] {
        // One model has dozens of providers; picking by price (the default) often lands on slow ones. Picking by recent response speed cuts one judgment from about 3 s to about 1.7 s.
        // Cards understood in the background are picked this way too (on purpose: during personal use, the unit price is at most double, still under a cent per card)
        self == .openRouter ? ["provider": ["sort": "latency"]] : [:]
    }

    /// Usage for streamed answers: OpenRouter, DeepSeek and Zhipu include it in the last piece by default; others must be asked explicitly
    var streamExtras: [String: Any] {
        switch self {
        case .openRouter, .deepSeek, .zhipu: [:]
        default: ["stream_options": ["include_usage": true]]
        }
    }
}

/// How to connect to the cloud: which provider, which model, whether to think. Changed in Settings
public struct CloudSetup: Sendable, Equatable {
    public var vendor: Vendor
    /// API address of a custom provider
    public var address: String
    /// Leave empty to use this provider's default
    public var model: String
    /// Which model to use separately for judging (understanding a search sentence, ranking results); leave empty for this provider's default: Jev for OpenRouter, mostly the same as model
    public var judgeModel: String
    /// Think first before answering in discussions: more careful, and slower
    public var thinking: Bool

    public init(vendor: Vendor = .openRouter, address: String = "", model: String = "", judgeModel: String = "", thinking: Bool = false) {
        (self.vendor, self.address, self.model, self.judgeModel, self.thinking) = (vendor, address, model, judgeModel, thinking)
    }

    /// The model actually used; nil for custom when none is entered
    public var chosenModel: String? { model.isEmpty ? vendor.defaultModel : model }

    /// Judging goes to Jev: only OpenRouter routes it, and it's the default there; not used if another judge model is entered
    public var usesJev: Bool { vendor == .openRouter && (judgeModel.isEmpty || judgeModel == Jev.model) }

    /// Which model to use when judging with a generation model
    var chosenJudgeModel: String? { judgeModel.isEmpty || usesJev ? vendor.defaultJudgeModel ?? chosenModel : judgeModel }

    /// Where requests go: custom addresses may include a trailing slash or the whole /chat/completions
    var base: URL? {
        guard vendor == .custom else { return URL(string: vendor.address!) }
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/chat/completions") { text.removeLast("/chat/completions".count) }
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true, url.host != nil else { return nil }
        return url
    }
}
