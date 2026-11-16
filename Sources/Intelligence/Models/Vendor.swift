import Foundation

/// 云端服务商。除了 Claude 用自己的接口（见 Claude.swift），各家的请求格式相同（chat/completions），
/// 不同的只有这里列的几处：地址、默认模型、思考怎么调、认不认几个附加参数。加一家就是加一个 case，把这几处填上。
/// 各家的写法和默认模型按 2026-11 的官方文档定
public enum Vendor: String, CaseIterable, Sendable, Identifiable {
    /// 密钥文件、偏好设置都按 rawValue 记，改了就读不到老的；OpenRouter 沿用原来存密钥的名字
    case openRouter = "OpenRouter"
    case deepSeek, volcano, bailian, siliconFlow, zhipu, kimi, miniMax, anthropic, gemini, openAI, custom

    public var id: Self { self }

    /// 设置里下拉的分组：转接多家的、国内的、海外的、自己填的
    public static let groups: [[Vendor]] = [[.openRouter], [.deepSeek, .volcano, .bailian, .siliconFlow, .zhipu, .kimi, .miniMax],
                                            [.anthropic, .gemini, .openAI], [.custom]]

    /// 请求格式：多数是 chat/completions；Claude 用 Anthropic 自己的 messages，密钥放的请求头也不同
    enum Wire { case chat, messages }
    var wire: Wire { self == .anthropic ? .messages : .chat }

    /// 给人看的名字
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

    /// 接口地址，后面接 /chat/completions（Claude 接 /messages）。自定义的由用户填
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

    /// 不填模型名时用哪个：要能看图、能调工具，偏快偏省。自定义的没有
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

    /// 不填判断模型时用哪个：判断是搜索时有人在等的，取这家更快的一档；nil 表示和 defaultModel 相同（默认的已经是快的那档，
    /// 或者还没查到这家更快又能看图的型号）。OpenRouter 默认用 Jev，不走这里（见 CloudSetup.usesJev）
    public var defaultJudgeModel: String? { self == .openAI ? "gpt-6-luna" : nil }

    /// 请求里调思考的那几项。多数模型默认开着思考，所以关也要明说；关不掉的那几家，「关」就是想得最少的那一档
    func thinkingFields(on: Bool) -> [String: Any] {
        switch self {
        // OpenRouter 的统一写法，由它翻译给各家
        case .openRouter: ["reasoning": ["enabled": on]]
        case .deepSeek, .volcano: ["thinking": ["type": on ? "enabled" : "disabled"]]
        case .bailian: ["enable_thinking": on]
        // 只在打开时发：不认这个参数的模型收到会不会报错，文档没说
        case .siliconFlow: on ? ["enable_thinking": true] : [:]
        // 这三家的默认模型关不掉思考，只分档
        case .zhipu, .kimi, .gemini: ["reasoning_effort": on ? "high" : "low"]
        // reasoning_split：想的内容单独放，不混在回答里
        case .miniMax: ["reasoning_effort": on ? "high" : "low", "reasoning_split": true]
        case .openAI: ["reasoning_effort": on ? "high" : "none"]
        // Claude 的接口另写；自定义的不知道怎么写，不发，由模型自己的默认决定
        case .anthropic, .custom: [:]
        }
    }

    /// 思考开关对这家管不管用
    public var canSetThinking: Bool { self != .custom }

    /// 模型上一轮想的内容要不要随讨论记录带回去。文档要求带回的才带：DeepSeek 带着工具时不带会报错，Kimi、MiniMax 要靠它接着想；
    /// OpenRouter 转给它们。别家带回去只是多花钱。自定义的：收到过这种内容，说明它讲的就是这种写法，也带回
    var sendsThoughtsBack: Bool {
        switch self {
        case .openRouter, .deepSeek, .kimi, .miniMax, .custom: true
        default: false
        }
    }

    /// 服务商附在工具调用上的东西要不要带回：Gemini 靠它接着想。别家没有这东西，换服务商接着聊时不能把 Gemini 的发给它们
    var sendsCallExtrasBack: Bool { self == .gemini || self == .custom }

    /// 认不认「按 JSON 回答」这个参数。其余几家要么只有部分模型认，要么和思考、看图冲突，就不发：提示词里已经要求只输出 JSON
    var jsonMode: Bool { self == .openRouter || self == .deepSeek }

    /// 只有 OpenRouter 才有的几项
    var extras: [String: Any] {
        // 同一个模型有几十家服务商，默认按价格挑，常落到慢的那几家；按最近的响应速度挑，一次判断从 3 秒左右降到 1.7 秒左右。
        // 后台理解卡片也这样挑（有意的：自用阶段，单价最多贵一倍，一张卡仍不到一分钱）
        self == .openRouter ? ["provider": ["sort": "latency"]] : [:]
    }

    /// 流式回答的用量：OpenRouter、DeepSeek、智谱默认带在最后一段，别家要明说才带
    var streamExtras: [String: Any] {
        switch self {
        case .openRouter, .deepSeek, .zhipu: [:]
        default: ["stream_options": ["include_usage": true]]
        }
    }
}

/// 云端怎么接：哪家、哪个模型、要不要思考。设置里改
public struct CloudSetup: Sendable, Equatable {
    public var vendor: Vendor
    /// 自定义服务商的接口地址
    public var address: String
    /// 留空用这家默认的
    public var model: String
    /// 判断另用哪个模型（搜索时理解一句话、给结果排序）；留空用这家默认的：OpenRouter 是 Jev，多数和 model 相同
    public var judgeModel: String
    /// 讨论时先想一遍再答：更仔细，也更慢
    public var thinking: Bool

    public init(vendor: Vendor = .openRouter, address: String = "", model: String = "", judgeModel: String = "", thinking: Bool = false) {
        (self.vendor, self.address, self.model, self.judgeModel, self.thinking) = (vendor, address, model, judgeModel, thinking)
    }

    /// 实际用的模型；自定义的没填时为 nil
    public var chosenModel: String? { model.isEmpty ? vendor.defaultModel : model }

    /// 判断交给 Jev：只有 OpenRouter 转接它，是那里默认的；填了别的判断模型就不用它
    public var usesJev: Bool { vendor == .openRouter && (judgeModel.isEmpty || judgeModel == Jev.model) }

    /// 拿生成模型来判断时用哪个
    var chosenJudgeModel: String? { judgeModel.isEmpty || usesJev ? vendor.defaultJudgeModel ?? chosenModel : judgeModel }

    /// 请求发到哪：自定义的地址容许带着结尾的斜杠或整条 /chat/completions
    var base: URL? {
        guard vendor == .custom else { return URL(string: vendor.address!) }
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/chat/completions") { text.removeLast("/chat/completions".count) }
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true, url.host != nil else { return nil }
        return url
    }
}
