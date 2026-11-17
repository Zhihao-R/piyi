import Foundation
import Library

// Model access: the single gateway for all model calls.
// Upper layers only say which capability they need; which provider backs it is decided here.

/// One provider. Generation and judging can have several; earlier ones are used first
public protocol Provider: Sendable {
    /// Name for people; Settings uses it to keep keys apart
    var name: String { get }
    /// Usable right now: cloud needs a working key, local needs the model file present
    var isReady: Bool { get }
}

/// A provider that needs a key (cloud). The settings page shows a key field for each one in this list
public protocol Keyed: Provider {
    var keyState: KeyState { get }
    /// An empty string means delete
    func setKey(_ key: String) throws
}

public enum KeyState: Sendable, Equatable {
    case missing
    /// Entered, but the provider rejected it (mistyped, revoked). Recovers with a different key
    case rejected
    case ready
}

/// Embedding: text → a list of numbers (unit length, so similarity is just the dot product)
public protocol Embedding: Provider {
    /// Model name, stored next to the embeddings; changing the model means recomputing them all
    var model: String { get }
    func embed(_ text: String, as role: EmbeddingRole) async throws -> [Float]
}

/// Cards and queries are written differently (queries add a task instruction)
public enum EmbeddingRole: Sendable { case card, query }

/// Generation: text + images → text. The gateway always asks for a JSON answer; see Gateway.generate
public protocol Generation: Provider {
    /// careful: think a bit longer (used when judgment isn't confident enough); slower
    func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String
}

/// Judging: several questions about the same content, each with options → which one each picks, and how confident
public protocol Judgment: Provider {
    /// Whether it can see images. Judgments that need the image ("a man who looks like a dog") only go to ones that can
    var seesImages: Bool { get }
    /// Confidence below this counts as not confident. Providers report confidence differently, so this line is set from each one's test data and isn't universal
    var sureEnough: Double { get }
    /// Several questions answered at once; conclusions follow the order of questions
    func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict]
    /// Ask the same question for each item in a batch (search reranking, topic filtering): one conclusion per item, in the order of items. images are attached to the whole batch; items refer to them as "image n"
    func judge(each items: [String], _ question: Question, about facts: Facts, images: [Data]) async throws -> [Verdict]
}

extension Judgment {
    /// By default each item is written into the questions and asked in one go like any other; providers that can only take one question at a time implement their own
    public func judge(each items: [String], _ question: Question, about facts: Facts, images: [Data]) async throws -> [Verdict] {
        try await judge(facts, items.map { question.about($0) }, images: images)
    }
}

/// The content to judge: several ordered "name: text" items, e.g. URL, title, page text
public typealias Facts = [(name: String, text: String)]

public struct Question: Sendable {
    public var text: String
    public var answers: Answers

    public enum Answers: Sendable {
        /// Yes or no: conclusion 0 is "yes"
        case yesNo
        /// Several parallel options: key is a short English name, text is for the model
        case choice([(key: String, text: String)])
        /// Several levels from low to high (relevance): scoring by level suits the judge model better than treating them as parallel options
        case grade([String])
    }

    public init(_ text: String, _ answers: Answers) {
        self.text = text
        self.answers = answers
    }

    /// Option text for the model
    var options: [String] {
        switch answers {
        case .yesNo: ["是", "否"]
        case .choice(let options): options.map(\.text)
        case .grade(let levels): levels
        }
    }

    /// A question with parallel options: which key the conclusion picked
    public func key(of verdict: Verdict) -> String? {
        guard case .choice(let options) = answers, options.indices.contains(verdict.choice) else { return nil }
        return options[verdict.choice].key
    }

    /// The same question asked about one specific item
    func about(_ item: String) -> Question { Question("\(text)\n\(item)", answers) }
}

public struct Verdict: Sendable, Equatable {
    /// Option index; for yes-or-no questions 0 is "yes"
    public var choice: Int
    /// 0～1
    public var confidence: Double

    public init(choice: Int, confidence: Double) {
        self.choice = choice
        self.confidence = confidence
    }

    public var yes: Bool { choice == 0 }
}

/// Transcription: audio (sound taken from video files) → timed sentences of text
public protocol Transcription: Provider {
    func transcribe(_ file: URL) async throws -> [Cue]
}

/// Chat: a list of messages (may include images) and available tools → pieces arriving in order: text, tool calls, and finally the end
public protocol Conversation: Provider {
    /// How much the model can read at once (tokens); nil when it can't be asked
    func contextLength() async -> Int?
    func converse(_ chat: Chat) -> AsyncThrowingStream<ChatChunk, Error>
}

public struct Chat: Sendable, Equatable {
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    /// false: tool descriptions are included, but the model may only answer with what it has (tool rounds hit the cap)
    public var toolsAllowed = true
    /// Where the unchanging start ends (inclusive): providers that need explicit cache marks mark here; ones that cache automatically don't need to
    public var stableThrough: Position?

    /// Which piece of which message
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
    /// Tools the assistant wants to call
    public var calls: [ToolCall] = []
    /// Which call a tool result answers
    public var callID: String?

    /// The assistant's thinking this round: some providers require it sent back unchanged
    public var thought: String?

    public init(_ role: Role, _ parts: [Part], calls: [ToolCall] = [], callID: String? = nil, thought: String? = nil) {
        (self.role, self.parts, self.calls, self.callID, self.thought) = (role, parts, calls, callID, thought)
    }

    public static func text(_ role: Role, _ text: String) -> ChatMessage { ChatMessage(role, [.text(text)]) }

    /// Text parts joined together
    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }
}

/// A tool for the model: English name, when to use it, parameter format (JSON Schema)
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
    /// Thinking, not shown to people
    case thought(String)
    case call(ToolCall)
    case done(ChatUsage)
}

/// Usage for one chat: how much was read (and how much hit the cache), how much written, how many USD spent
public struct ChatUsage: Sendable, Equatable {
    public var input = 0, cached = 0, output = 0
    public var cost = 0.0

    public init(input: Int = 0, cached: Int = 0, output: Int = 0, cost: Double = 0) {
        (self.input, self.cached, self.output, self.cost) = (input, cached, output, cost)
    }
}

/// A capability can't be used right now
public enum Unavailable: Error, Equatable {
    /// No provider, or one that isn't usable yet: cloud has no key or the key was rejected, local model not downloaded
    case notReady
}

/// The model's answer isn't the agreed JSON
public struct MalformedReply: LocalizedError {
    public var errorDescription: String? { String(localized: "模型的回答格式不对") }
}

public final class Gateway: Sendable {
    /// There is only one embedding model: search compares every card's embedding on one ruler, and embeddings from two models can't be compared.
    /// It was decided when choosing models that embeddings are all computed locally
    let embedder: (any Embedding)?
    let generators: [any Generation]
    let judges: [any Judgment]
    /// Dedicated judging providers (the first ones in judges), excluding generation standing in
    let dedicatedJudges: [any Judgment]
    let transcribers: [any Transcription]
    let conversers: [any Conversation]

    /// judging: generation providers used to stand in for judging (may use a separate faster model); falls back to generators if not given
    public init(embedder: (any Embedding)?, generators: [any Generation], judges: [any Judgment] = [], judging: [any Generation]? = nil,
                transcribers: [any Transcription] = [], conversers: [any Conversation] = []) {
        self.embedder = embedder
        self.generators = generators
        // Dedicated judging providers first; when images must be seen or there's no dedicated provider, use generation to judge
        self.judges = judges + (judging ?? generators).map { GeneratedJudgment(generation: $0, careful: false) }
        dedicatedJudges = judges
        self.transcribers = transcribers
        self.conversers = conversers
    }

    // MARK: Five capabilities

    /// Name of the embedding model; nil while the model isn't downloaded yet
    public var embeddingModel: String? { embedder.flatMap { $0.isReady ? $0.model : nil } }

    public func embed(_ text: String, as role: EmbeddingRole) async throws -> [Float] {
        guard let embedder, embedder.isReady else { throw Unavailable.notReady }
        return try await embedder.embed(text, as: role)
    }

    /// Answer as JSON and decode into T
    public func generate<T: Decodable>(_ prompt: String, images: [Data] = [], as type: T.Type) async throws -> T {
        let text = try await generators[ready(generators)[0]].generate(prompt, images: images, careful: false)
        return try Self.decode(T.self, from: text)
    }

    /// Several questions asked in one go (one sentence in the search box: intent and several conditions).
    /// When fallback is false only dedicated judging providers are asked, never falling back to the generation model: the caller set its threshold on their probability scale (sorting), and confidence reported by a generation model can't be compared against the same line
    public func judge(_ facts: Facts, _ questions: [Question], images: [Data] = [], fallback: Bool = true) async throws -> [Verdict] {
        try await judging(images: images, fallback: fallback) { judge in
            let verdicts = try await judge.judge(facts, questions, images: images)
            guard verdicts.count == questions.count else { throw MalformedReply() }
            return verdicts
        }.answer
    }

    /// Judge a batch item by item on the same question. recheck: items without enough confidence go to generation to think carefully once and judge again, waiting at most recheckTimeout seconds each;
    /// those not back in time keep the first-pass conclusion. Only places where nobody is waiting (inspiration prepared in the background) recheck: thinking carefully once takes 2–20 seconds
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

    /// Ask usable judging providers in order (only those that can see images when there are images), moving to the next if one errors: when Jev errors, fall back to the generation model, not straight to keyword rules
    private func judging<T>(images: [Data], fallback: Bool = true, _ ask: (any Judgment) async throws -> T) async throws -> (judge: any Judgment, answer: T) {
        let pool = fallback ? judges : dedicatedJudges
        let candidates = images.isEmpty ? pool : pool.filter(\.seesImages)
        var failure: Error = Unavailable.notReady
        for i in try ready(candidates) {
            do { return (candidates[i], try await ask(candidates[i])) } catch {
                // The caller stopped waiting (timeout): don't move on to the next one
                if Task.isCancelled { throw error }
                failure = error
            }
        }
        throw failure
    }

    public func transcribe(_ file: URL) async throws -> [Cue] {
        try await transcribers[ready(transcribers)[0]].transcribe(file)
    }

    /// Chat: uses the first usable one. Returns a stream; cancelling the read ends this call
    public func converse(_ chat: Chat) throws -> AsyncThrowingStream<ChatChunk, Error> {
        try conversers[ready(conversers)[0]].converse(chat)
    }

    /// Context length of the chat model: changes with the model
    public func contextLength() async -> Int? {
        guard let i = try? ready(conversers)[0] else { return nil }
        return await conversers[i].contextLength()
    }

    public var canConverse: Bool { conversers.contains(where: \.isReady) }

    /// Whether generation is usable now: a provider has a working key (or the local model file is present)
    public var canGenerate: Bool { generators.contains(where: \.isReady) }

    /// Whether judging is usable now (search understanding, reranking, topic filtering)
    public var canJudge: Bool { judges.contains(where: \.isReady) }

    /// Whether automatic sorting is usable now: it only accepts dedicated judging providers (see judge's fallback)
    public var canSort: Bool { dedicatedJudges.contains(where: \.isReady) }

    /// Usable providers (indexes, in order); throws notReady when none is usable
    private func ready(_ providers: [any Provider]) throws -> [Int] {
        let ready = providers.indices.filter { providers[$0].isReady }
        guard !ready.isEmpty else { throw Unavailable.notReady }
        return ready
    }

    /// Some models wrap the answer in a ```json code block: take from the first { to the last }
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let value = try? JSONDecoder().decode(T.self, from: Data(text[start...end].utf8)) else { throw MalformedReply() }
        return value
    }
}

/// Judging implemented with generation: have the model answer in JSON which option and how confident
struct GeneratedJudgment: Judgment {
    let generation: any Generation
    let careful: Bool

    var name: String { generation.name }
    var isReady: Bool { generation.isReady }
    var seesImages: Bool { true }
    /// deepseek's reported confidence runs high overall: 97% of questions above 0.75 (tested when choosing models)
    var sureEnough: Double { 0.75 }

    /// One question per request, several sent at once
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

    /// Answer a batch at once: saves the round trips of per-item requests. The model writes a conclusion per item, and the longer it writes the slower it is (with a confidence decimal per item, 48 items take nearly 500 tokens),
    /// so it only writes option numbers and lists uncertain ones separately: confidence is just "confident" or "not confident"
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

    /// In a batch, only confident or not; converted to a confidence value
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
