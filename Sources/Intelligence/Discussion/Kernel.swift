import Foundation
import Library

/// Discussion kernel: reads the discussion record, assembles what's sent to the model, calls the model, runs tools, checks citations, writes the record.
/// It keeps no state of its own and rereads the record at every step: nothing is lost if the process exits or the implementation changes. Text halfway through generation lives only in memory; stopping counts as "didn't finish"
public final class DiscussionKernel: Sendable {
    let store: Store
    let gateway: Gateway
    let tools: [any Tool]
    let recipe: any Recipe

    /// At most how many tool rounds one question can take (tentative); once reached, the model answers with what it already has
    public static let toolRounds = 20
    /// Max length of text a tool hands to the model, in characters (tentative)
    static let resultLimit = 4000
    /// At most what share of the model's context the desk's cards may take (tentative); the rest is left for the conversation and the answer
    static let deskShare = 0.5
    /// Rough length estimate: about 1 token per character (on the safe side); an image counts as this many
    static let pictureTokens = 800

    public init(store: Store, gateway: Gateway, tools: [any Tool], recipe: any Recipe = WholeText()) {
        (self.store, self.gateway, self.tools, self.recipe) = (store, gateway, tools, recipe)
    }

    public enum Progress: Sendable {
        /// The answer being generated, full text so far
        case writing(String)
        /// A new entry was written to the discussion record
        case recorded
    }

    /// What's sent to the model exceeds its limit: start a new discussion
    public struct TooLong: LocalizedError {
        public var errorDescription: String? { String(localized: "这段讨论太长了") }
    }

    /// This round's cost, speed and caching, recorded by the test set
    public struct Report: Sendable {
        public var usage = ChatUsage()
        /// From start to the first character of the answer
        public var firstText: Duration?
    }

    // MARK: Run one round

    /// What to do next: looks only at the discussion record, spotting unfinished work by whether questions and answers, calls and results are paired up
    enum Step: Equatable {
        case idle
        /// A tool was called but no result arrived (exited midway): fill it in first
        case runTools([ToolCall], round: Int)
        /// Call the model. round is how many tool rounds this question has already taken
        case ask(round: Int)
    }

    /// A question wasn't fully answered (exited midway, offline, error, stopped): the interface shows "Answer didn’t finish" and a retry here
    public static func isUnfinished(_ events: [DiscussionEvent]) -> Bool { next(events) != .idle }

    static func next(_ events: [DiscussionEvent]) -> Step {
        guard let q = events.lastIndex(where: { if case .question = $0.what { true } else { false } }) else { return .idle }
        let after = events[(q + 1)...]
        if after.contains(where: { if case .answer = $0.what { true } else { false } }) { return .idle }
        let answered = Set(after.compactMap { if case .result(let r) = $0.what { r.call } else { nil } })
        var round = 0
        for event in after {
            guard case .calls(_, _, let calls) = event.what else { continue }
            round += 1
            let missing = calls.filter { !answered.contains($0.id) }
            if !missing.isEmpty { return .runTools(missing, round: round) }
        }
        return .ask(round: round)
    }

    /// Finish whatever this discussion left undone until an answer is written. If cancelled midway, records already written stay and the next run picks up from there
    @discardableResult
    public func run(_ discussion: Int64, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Report {
        var report = Report()
        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let events = try await store.events(of: discussion)
            switch Self.next(events) {
            case .idle:
                return report
            case .runTools(let calls, _):
                let desk = Set(try await store.desk(of: discussion).compactMap(\.id))
                for call in calls {
                    let result = try await execute(call, desk: desk)
                    // Stopped: this call counts as not made and is redone next time; no half-finished result is written
                    try Task.checkCancellation()
                    try await store.append([.result(result)], to: discussion)
                    progress(.recorded)
                }
            case .ask(let round):
                let desk = try await deskCards(discussion)
                var chat = recipe.chat(desk: desk, events: events, tools: tools.map(\.spec))
                chat.toolsAllowed = round < Self.toolRounds
                if let length = await gateway.contextLength(), Self.estimate(chat) > length { throw TooLong() }
                var text = "", thought = "", calls: [ToolCall] = []
                for try await chunk in try gateway.converse(chat) {
                    switch chunk {
                    case .text(let piece):
                        if report.firstText == nil { report.firstText = ContinuousClock.now - started }
                        text += piece
                        progress(.writing(text))
                    case .thought(let piece): thought += piece
                    case .call(let call): calls.append(call)
                    case .done(let usage):
                        report.usage.input += usage.input
                        report.usage.cached += usage.cached
                        report.usage.output += usage.output
                        report.usage.cost += usage.cost
                    }
                }
                try Task.checkCancellation()
                if !calls.isEmpty, chat.toolsAllowed {
                    try await store.append([.calls(said: text, thought: thought.isEmpty ? nil : thought, calls)], to: discussion)
                } else {
                    var answer = Citations.check(text, against: Self.sources(desk, events))
                    if !thought.isEmpty { answer.thought = thought }
                    try await store.append([.answer(answer)], to: discussion)
                }
                progress(.recorded)
            }
        }
    }

    /// Run one tool call. Errors, unknown tools, and tools that change data (not run in the first version) all report "didn't succeed", and the model answers with what it already has;
    /// stopping is still thrown
    func execute(_ call: ToolCall, desk: Set<Int64>) async throws -> ToolResult {
        guard let tool = tools.first(where: { $0.spec.name == call.name }), tool.nature == .reading else {
            return ToolResult(call: call.id, label: String(localized: "\(call.name)没成功"), text: "工具失败：没有这个工具", failed: true)
        }
        do {
            let output = try await tool.run(call.arguments, desk: desk)
            return ToolResult(call: call.id, label: String(localized: "\(tool.title)：\(output.detail)"), text: String(output.text.prefix(Self.resultLimit)),
                              items: output.items, shown: output.shown, cost: output.cost)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ToolResult(call: call.id, label: String(localized: "\(tool.title)没成功"), text: String(localized: "工具失败：\(error.localizedDescription)"), failed: true)
        }
    }

    // MARK: Desk

    /// Cards on the desk: paragraphs are split and numbered fresh each round (splitting is fast enough that there's no need to store it ahead), image cards carry the image
    func deskCards(_ discussion: Int64) async throws -> [DeskCard] {
        await deskCards(try await store.desk(of: discussion))
    }

    func deskCards(_ cards: [Card]) async -> [DeskCard] {
        var out: [DeskCard] = []
        for card in cards {
            let pictures = card.kind == .image && card.trashedAt == nil ? await Prompt.images(for: card, store: store) : []
            out.append(DeskCard(card: card, passages: Passages.of(card), pictures: pictures))
        }
        return out
    }

    /// Do these cards fit on the desk together: estimated from the desk as the recipe actually assembles it, taking at most half the model's context. Not blocked when the context length can't be found
    public func fits(_ cards: [Card]) async -> Bool {
        guard let length = await gateway.contextLength() else { return true }
        let chat = recipe.chat(desk: await deskCards(cards), events: [], tools: [])
        return Double(Self.estimate(chat)) <= Double(length) * Self.deskShare
    }

    /// Rough token count of what's sent to the model
    static func estimate(_ chat: Chat) -> Int {
        chat.messages.reduce(0) { total, message in
            total + message.parts.reduce(0) { sum, part in
                switch part {
                case .text(let text): sum + text.count
                case .image: sum + pictureTokens
                }
            } + message.calls.reduce(0) { $0 + $1.arguments.count } + (message.thought?.count ?? 0)
        }
    }

    /// What citations are checked against: paragraphs of cards on the desk (not in the trash), and the items each tool call returned
    static func sources(_ desk: [DeskCard], _ events: [DiscussionEvent]) -> Citations.Sources {
        let cards = Dictionary(uniqueKeysWithValues: desk.filter { $0.card.trashedAt == nil }.map { ($0.id, (title: $0.card.displayTitle, passages: $0.passages)) })
        let order: [String] = events.flatMap { event -> [String] in if case .calls(_, _, let calls) = event.what { calls.map(\.id) } else { [] } }
        let items = Dictionary(events.compactMap { event -> (String, [String])? in if case .result(let r) = event.what { (r.call, r.items) } else { nil } },
                               uniquingKeysWith: { a, _ in a })
        var results: [Int: [String]] = [:]
        for (i, id) in order.enumerated() { results[i + 1] = items[id] ?? [] }
        return Citations.Sources(cards: cards, results: results)
    }

    // MARK: Naming

    /// After the first answer comes out, give it a name of at most 12 characters (6 words in English), in the same language as the question. If none comes out it stays "New Discussion", without bothering you.
    /// Separate from running a round: you can ask again right after the answer without waiting for the name
    public func nameIfNeeded(_ discussion: Int64) async {
        guard (try? await store.discussion(discussion))??.name == nil, let events = try? await store.events(of: discussion),
              case .question(let asked)? = events.last(where: { if case .question = $0.what { true } else { false } })?.what,
              case .answer(let answer)? = events.last(where: { if case .answer = $0.what { true } else { false } })?.what else { return }
        struct Reply: Decodable { var name: String }
        let prompt = """
            给下面这段讨论起一个名字，说清在讨论什么，不加引号和标点。用和提问相同的语言：中文 12 个字以内，其他语言 6 个词以内。
            问：\(asked.prefix(300))
            答：\(Citations.plain(answer.text).prefix(600))
            只输出 JSON：{"name":"名字"}
            """
        let gateway = gateway
        guard let reply = await within(10, { try await gateway.generate(prompt, as: Reply.self) }) else { return }
        let name = Writing.clip(reply.name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)), to: 12)
        guard !name.isEmpty else { return }
        try? await store.renameDiscussion(discussion, to: name)
    }
}
