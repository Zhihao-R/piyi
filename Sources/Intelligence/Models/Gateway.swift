import Foundation
import Library

// 模型接入：所有模型调用的唯一出口。
// 上层只说要哪种能力；挂哪个服务方在这里定。

/// 一个服务方。生成、判断可以接多个，排在前面的先用
public protocol Provider: Sendable {
    /// 给人看的名字，设置里按它分别填密钥
    var name: String { get }
    /// 现在能不能用：云端要填了能用的密钥，本机要模型文件在
    var isReady: Bool { get }
}

/// 要填密钥的服务方（云端）。设置页按这个列表逐个显示密钥框
public protocol Keyed: Provider {
    var keyState: KeyState { get }
    /// 空字符串表示删掉
    func setKey(_ key: String) throws
}

public enum KeyState: Sendable, Equatable {
    case missing
    /// 填了，但服务方拒绝（填错了、作废了）。换一把就恢复
    case rejected
    case ready
}

/// 向量：文字 → 一串数字（单位长度，相似度直接用点积）
public protocol Embedding: Provider {
    /// 模型名，存在向量旁边；换了模型向量要整批重算
    var model: String { get }
    func embed(_ text: String, as role: EmbeddingRole) async throws -> [Float]
}

/// 卡片和查询的写法不同（查询要加一句任务说明）
public enum EmbeddingRole: Sendable { case card, query }

/// 生成：文字 + 图片 → 文字。出口总是要求按 JSON 回答，见 Gateway.generate
public protocol Generation: Provider {
    /// careful：多想一会儿（判断把握不够时用），慢一些
    func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String
}

/// 判断：关于同一段内容问几道题，每道给几个选项 → 各选哪个、有多大把握
public protocol Judgment: Provider {
    /// 能不能看图。要看图才判断得了的（「长得像狗的男人」）只交给能看的
    var seesImages: Bool { get }
    /// 把握低于这个算没把握。各家报把握的习惯不同，这条线按各自的测试数据定，不能通用
    var sureEnough: Double { get }
    /// 几道题一次答完，结论顺序跟着 questions
    func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict]
    /// 同一道题逐条问一批（搜索精排、主题筛选）：每条一个结论，顺序跟着 items。images 附在整批上，条目里写「附图 n」指认
    func judge(each items: [String], _ question: Question, about facts: Facts, images: [Data]) async throws -> [Verdict]
}

extension Judgment {
    /// 默认把每条写进题目里，和别的题一样一次问完；只会一题一问的服务方自己实现
    public func judge(each items: [String], _ question: Question, about facts: Facts, images: [Data]) async throws -> [Verdict] {
        try await judge(facts, items.map { question.about($0) }, images: images)
    }
}

/// 要判断的内容：按顺序的几项「名称：文字」，比如「网址」「标题」「页面文字」
public typealias Facts = [(name: String, text: String)]

public struct Question: Sendable {
    public var text: String
    public var answers: Answers

    public enum Answers: Sendable {
        /// 是或否：结论 0 是「是」
        case yesNo
        /// 几个并列的选项：key 是简短的英文名，text 给模型看
        case choice([(key: String, text: String)])
        /// 由低到高的几个等级（相关程度）：按等级打分，比当成并列选项更合判断模型的路子
        case grade([String])
    }

    public init(_ text: String, _ answers: Answers) {
        self.text = text
        self.answers = answers
    }

    /// 给模型看的选项文字
    var options: [String] {
        switch answers {
        case .yesNo: ["是", "否"]
        case .choice(let options): options.map(\.text)
        case .grade(let levels): levels
        }
    }

    /// 并列选项的题：结论选的是哪个 key
    public func key(of verdict: Verdict) -> String? {
        guard case .choice(let options) = answers, options.indices.contains(verdict.choice) else { return nil }
        return options[verdict.choice].key
    }

    /// 同一道题问到具体的一条上
    func about(_ item: String) -> Question { Question("\(text)\n\(item)", answers) }
}

public struct Verdict: Sendable, Equatable {
    /// 选项的下标；是或否的题 0 是「是」
    public var choice: Int
    /// 0～1
    public var confidence: Double

    public init(choice: Int, confidence: Double) {
        self.choice = choice
        self.confidence = confidence
    }

    public var yes: Bool { choice == 0 }
}

/// 转录：音频（视频文件取声音）→ 一句句带时间的文字
public protocol Transcription: Provider {
    func transcribe(_ file: URL) async throws -> [Cue]
}

/// 对话：一串消息（可以带图）和可用的工具 → 按顺序到达的片段：文字、工具调用，最后是结束
public protocol Conversation: Provider {
    /// 模型一次能读多长（token）；问不到时为 nil
    func contextLength() async -> Int?
    func converse(_ chat: Chat) -> AsyncThrowingStream<ChatChunk, Error>
}

public struct Chat: Sendable, Equatable {
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    /// false：带着工具说明，但只让模型用已有的信息作答（工具轮数到了上限）
    public var toolsAllowed = true
    /// 不变的开头到哪一处为止（含）：要显式标缓存的服务方在这里标，自动缓存的服务方不用
    public var stableThrough: Position?

    /// 第几条消息的第几段
    public struct Position: Sendable, Equatable {
        public var message: Int, part: Int
        public init(message: Int, part: Int) { (self.message, self.part) = (message, part) }
    }

    public init(messages: [ChatMessage], tools: [ToolSpec], toolsAllowed: Bool = true, stableThrough: Position? = nil) {
        (self.messages, self.tools, self.toolsAllowed, self.stableThrough) = (messages, tools, toolsAllowed, stableThrough)
    }
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public enum Part: Sendable, Equatable { case text(String), image(Data) }

    public var role: Role
    public var parts: [Part]
    /// 助手要调用的工具
    public var calls: [ToolCall] = []
    /// 工具结果对应哪次调用
    public var callID: String?

    public init(_ role: Role, _ parts: [Part], calls: [ToolCall] = [], callID: String? = nil) {
        (self.role, self.parts, self.calls, self.callID) = (role, parts, calls, callID)
    }

    public static func text(_ role: Role, _ text: String) -> ChatMessage { ChatMessage(role, [.text(text)]) }

    /// 文字部分连起来
    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }
}

/// 给模型看的一个工具：英文名、什么时候该用、参数格式（JSON Schema）
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: String

    public init(name: String, description: String, parameters: String) {
        (self.name, self.description, self.parameters) = (name, description, parameters)
    }
}

public enum ChatChunk: Sendable, Equatable {
    case text(String)
    case call(ToolCall)
    case done(ChatUsage)
}

/// 一次对话的用量：读了多少（其中多少命中缓存）、写了多少、花了多少美元
public struct ChatUsage: Sendable, Equatable {
    public var input = 0, cached = 0, output = 0
    public var cost = 0.0

    public init(input: Int = 0, cached: Int = 0, output: Int = 0, cost: Double = 0) {
        (self.input, self.cached, self.output, self.cost) = (input, cached, output, cost)
    }
}

/// 某种能力眼下用不了
public enum Unavailable: Error, Equatable {
    /// 没有服务方，或者有但还不能用：云端没填密钥或密钥被拒、本机模型没下载
    case notReady
}

/// 模型的回答不是约定的 JSON
public struct MalformedReply: LocalizedError {
    public var errorDescription: String? { "模型的回答格式不对" }
}

public final class Gateway: Sendable {
    /// 向量只有一个模型：搜索要把所有卡的向量放在一把尺子上比，两个模型算出的向量没法比较。
    /// 选型定了向量全在本机算
    let embedder: (any Embedding)?
    let generators: [any Generation]
    let judges: [any Judgment]
    /// 专门的判断服务方（judges 里排在前面的那几家），不含用生成能力冒充的
    let dedicatedJudges: [any Judgment]
    let transcribers: [any Transcription]
    let conversers: [any Conversation]

    public init(embedder: (any Embedding)?, generators: [any Generation], judges: [any Judgment] = [], transcribers: [any Transcription] = [],
                conversers: [any Conversation] = []) {
        self.embedder = embedder
        self.generators = generators
        // 专门的判断服务方在前；要看图时、没有专门的服务方时用生成能力来判断
        self.judges = judges + generators.map { GeneratedJudgment(generation: $0, careful: false) }
        dedicatedJudges = judges
        self.transcribers = transcribers
        self.conversers = conversers
    }

    // MARK: 五种能力

    /// 向量模型的名字；模型还没下载时为 nil
    public var embeddingModel: String? { embedder.flatMap { $0.isReady ? $0.model : nil } }

    public func embed(_ text: String, as role: EmbeddingRole) async throws -> [Float] {
        guard let embedder, embedder.isReady else { throw Unavailable.notReady }
        return try await embedder.embed(text, as: role)
    }

    /// 按 JSON 回答并解码成 T
    public func generate<T: Decodable>(_ prompt: String, images: [Data] = [], as type: T.Type) async throws -> T {
        let text = try await generators[ready(generators)[0]].generate(prompt, images: images, careful: false)
        return try Self.decode(T.self, from: text)
    }

    /// 几道题一次问完（搜索框里的一句话：意图和几种条件）。
    /// fallback 为 false 时只问专门的判断服务方，不退到生成模型：调用方按它的概率刻度定了线（分拣），生成模型报的把握没法用同一条线比
    public func judge(_ facts: Facts, _ questions: [Question], images: [Data] = [], fallback: Bool = true) async throws -> [Verdict] {
        try await judging(images: images, fallback: fallback) { judge in
            let verdicts = try await judge.judge(facts, questions, images: images)
            guard verdicts.count == questions.count else { throw MalformedReply() }
            return verdicts
        }.answer
    }

    /// 同一道题逐条判断一批。recheck：把握不够的那几条交给生成能力仔细想一次再判，每条最多等 recheckTimeout 秒，
    /// 没等到的留着第一遍的结论。只有不用人等的地方（后台备好的灵感）才 recheck：仔细想一次要 2～20 秒
    public func judge(each items: [String], _ question: Question, about facts: Facts = [], images: [Data] = [],
                      recheck: Bool = false) async throws -> [Verdict] {
        var (judge, verdicts) = try await judging(images: images) { judge in
            let verdicts = try await judge.judge(each: items, question, about: facts, images: images)
            guard verdicts.count == items.count else { throw MalformedReply() }
            return verdicts
        }
        guard recheck, let i = try? ready(generators)[0] else { return verdicts }
        let careful = GeneratedJudgment(generation: generators[i], careful: true)
        await withTaskGroup(of: (Int, Verdict?).self) { group in
            for (n, v) in verdicts.enumerated() where v.confidence < judge.sureEnough {
                group.addTask { (n, await within(Self.recheckTimeout) { try await careful.judge(facts, [question.about(items[n])], images: images)[0] }) }
            }
            for await (n, v) in group { if let v { verdicts[n] = v } }
        }
        return verdicts
    }

    static let recheckTimeout = 20.0

    /// 按顺序问能用的判断服务方（有图时只问看得了图的），前一家出错就问下一家：Jev 出错时退到生成模型，不直接退回关键词规则
    private func judging<T>(images: [Data], fallback: Bool = true, _ ask: (any Judgment) async throws -> T) async throws -> (judge: any Judgment, answer: T) {
        let pool = fallback ? judges : dedicatedJudges
        let candidates = images.isEmpty ? pool : pool.filter(\.seesImages)
        var failure: Error = Unavailable.notReady
        for i in try ready(candidates) {
            do { return (candidates[i], try await ask(candidates[i])) } catch {
                // 调用方不等了（超时），不再换下一家
                if Task.isCancelled { throw error }
                failure = error
            }
        }
        throw failure
    }

    public func transcribe(_ file: URL) async throws -> [Cue] {
        try await transcribers[ready(transcribers)[0]].transcribe(file)
    }

    /// 对话：用第一家能用的。流式返回，取消读取就断开这次调用
    public func converse(_ chat: Chat) throws -> AsyncThrowingStream<ChatChunk, Error> {
        try conversers[ready(conversers)[0]].converse(chat)
    }

    /// 对话模型的上下文长度：换了模型跟着变
    public func contextLength() async -> Int? {
        guard let i = try? ready(conversers)[0] else { return nil }
        return await conversers[i].contextLength()
    }

    public var canConverse: Bool { conversers.contains(where: \.isReady) }

    /// 生成能力现在能不能用：有服务方填了能用的密钥（本机的模型文件在）
    public var canGenerate: Bool { generators.contains(where: \.isReady) }

    /// 判断能力现在能不能用（搜索的理解、精排、主题筛选）
    public var canJudge: Bool { judges.contains(where: \.isReady) }

    /// 能用的服务方（下标，按排列顺序）；一个都不能用时抛 notReady
    private func ready(_ providers: [any Provider]) throws -> [Int] {
        let ready = providers.indices.filter { providers[$0].isReady }
        guard !ready.isEmpty else { throw Unavailable.notReady }
        return ready
    }

    /// 个别模型会包一层 ```json 代码块：取第一个 { 到最后一个 }
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let value = try? JSONDecoder().decode(T.self, from: Data(text[start...end].utf8)) else { throw MalformedReply() }
        return value
    }
}

/// 用生成能力实现的判断：让模型按 JSON 回答选哪个、有多大把握
struct GeneratedJudgment: Judgment {
    let generation: any Generation
    let careful: Bool

    var name: String { generation.name }
    var isReady: Bool { generation.isReady }
    var seesImages: Bool { true }
    /// deepseek 报的把握整体偏高：97% 的题在 0.75 以上（选模型时的测试）
    var sureEnough: Double { 0.75 }

    /// 一题一问，几道题同时发
    func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict] {
        try await withThrowingTaskGroup(of: (Int, Verdict).self) { group in
            for (i, question) in questions.enumerated() {
                group.addTask { (i, try await ask(facts, question, images: images)) }
            }
            var verdicts = [Verdict?](repeating: nil, count: questions.count)
            for try await (i, v) in group { verdicts[i] = v }
            return verdicts.map { $0! }
        }
    }

    private func ask(_ facts: Facts, _ question: Question, images: [Data]) async throws -> Verdict {
        let prompt = """
        \(Self.lines(facts))\(question.text)

        选项：
        \(Self.numbered(question.options))

        只输出 JSON：{"choice": 选项编号, "confidence": 0 到 1 之间的数，表示你有多大把握}
        """
        let answer = try Gateway.decode(Answer.self, from: try await generation.generate(prompt, images: images, careful: careful))
        return try answer.verdict(question.options)
    }

    /// 一次答一批：省掉逐条请求的往返。模型逐条写结论，写得越长越慢（每条带一个把握的小数时，48 条要写近 500 个词元），
    /// 所以只写选项编号，拿不准的另列出来：把握只分「有」「没有」
    func judge(each items: [String], _ question: Question, about facts: Facts, images: [Data]) async throws -> [Verdict] {
        let prompt = """
        \(Self.lines(facts))\(question.text)
        逐条判断下面每一项，选项：
        \(Self.numbered(question.options))

        条目：
        \(Self.numbered(items))

        只输出 JSON：{"choices":[按条目顺序，每条一个选项编号],"unsure":[拿不准的条目编号，没有就写 []]}
        """
        struct Reply: Decodable { var choices: [Int]; var unsure: [Int]? }
        let reply = try Gateway.decode(Reply.self, from: try await generation.generate(prompt, images: images, careful: careful))
        guard reply.choices.count == items.count else { throw MalformedReply() }
        let unsure = Set(reply.unsure ?? [])
        return try reply.choices.enumerated().map { i, choice in
            try Answer(choice: choice, confidence: unsure.contains(i + 1) ? Self.unsure : Self.sure).verdict(question.options)
        }
    }

    /// 一批里只分有没有把握，换算成把握的数值
    static let sure = 0.9, unsure = 0.5

    static func lines(_ facts: Facts) -> String {
        facts.map { "\($0.name)：\($0.text)\n" }.joined() + (facts.isEmpty ? "" : "\n")
    }

    static func numbered(_ lines: [String]) -> String {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    struct Answer: Decodable {
        var choice: Int
        var confidence: Double

        func verdict(_ options: [String]) throws -> Verdict {
            guard options.indices.contains(choice - 1) else { throw MalformedReply() }
            return Verdict(choice: choice - 1, confidence: min(max(confidence, 0), 1))
        }
    }
}
