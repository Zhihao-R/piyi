import Foundation
import Library

/// 讨论内核：读讨论记录、拼出发给模型的内容、调模型、执行工具、检查引用、写记录。
/// 自己不存任何状态，每一步都从记录重新读：进程退出、换实现都不丢东西。生成到一半的文字只在内存里，停下就算「没答完」
public final class DiscussionKernel: Sendable {
    let store: Store
    let gateway: Gateway
    let tools: [any Tool]
    let recipe: any Recipe

    /// 一个问题最多走几轮工具（暂定），到了就让模型用已有的信息作答
    public static let toolRounds = 20
    /// 工具交给模型的文字最长多少字（暂定）
    static let resultLimit = 4000
    /// 桌上的卡最多占模型上下文的多少（暂定），剩下的留给对话和回答
    static let deskShare = 0.5
    /// 粗估长度：一个字约 1 个 token（偏保守），一张图按这么多算
    static let pictureTokens = 800

    public init(store: Store, gateway: Gateway, tools: [any Tool], recipe: any Recipe = WholeText()) {
        (self.store, self.gateway, self.tools, self.recipe) = (store, gateway, tools, recipe)
    }

    public enum Progress: Sendable {
        /// 正在生成的回答，到目前为止的全文
        case writing(String)
        /// 讨论记录里写进了新的一条
        case recorded
    }

    /// 发给模型的内容超过了模型的上限：开一段新讨论
    public struct TooLong: LocalizedError {
        public var errorDescription: String? { String(localized: "这段讨论太长了") }
    }

    /// 这一轮的花费、速度和缓存，测试集记下来
    public struct Report: Sendable {
        public var usage = ChatUsage()
        /// 从开始到回答的第一个字
        public var firstText: Duration?
    }

    // MARK: 跑一轮

    /// 下一步做什么：只看讨论记录，靠问题和回答、调用和结果有没有配对认出没做完的事
    enum Step: Equatable {
        case idle
        /// 调用了工具却没等到结果的（中途退出），先补上
        case runTools([ToolCall], round: Int)
        /// 调模型。round 是这个问题已经走了几轮工具
        case ask(round: Int)
    }

    /// 有问题没答完（中途退出、断网、出错、停下）：界面在这里显示「没答完」和重试
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

    /// 接着做完这段讨论没做完的事，直到写下回答。中途取消的话已经写下的记录留着，下次从那里接着
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
                    // 停下了：这次调用算没做，下次重来，不写半截的结果
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

    /// 执行一次工具调用。出错、不认识的工具、改资料的工具（第一版不执行）都交回「没成功」，模型接着用已有的信息作答；
    /// 停下了照样抛出去
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

    // MARK: 桌

    /// 桌上的卡：每一轮现切段落、编号（切法够快，不必提前切好存着），图片卡带上图
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

    /// 这几张卡一起放得下桌吗：按拼法实际拼出的桌估，最多占模型上下文的一半。问不到上下文长度时不拦
    public func fits(_ cards: [Card]) async -> Bool {
        guard let length = await gateway.contextLength() else { return true }
        let chat = recipe.chat(desk: await deskCards(cards), events: [], tools: [])
        return Double(Self.estimate(chat)) <= Double(length) * Self.deskShare
    }

    /// 发给模型的内容粗估有多少 token
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

    /// 检查引用要对照的：桌上（不在废纸篓里）的卡的段落，和每次工具调用读回的几项
    static func sources(_ desk: [DeskCard], _ events: [DiscussionEvent]) -> Citations.Sources {
        let cards = Dictionary(uniqueKeysWithValues: desk.filter { $0.card.trashedAt == nil }.map { ($0.id, (title: $0.card.displayTitle, passages: $0.passages)) })
        let order: [String] = events.flatMap { event -> [String] in if case .calls(_, _, let calls) = event.what { calls.map(\.id) } else { [] } }
        let items = Dictionary(events.compactMap { event -> (String, [String])? in if case .result(let r) = event.what { (r.call, r.items) } else { nil } },
                               uniquingKeysWith: { a, _ in a })
        var results: [Int: [String]] = [:]
        for (i, id) in order.enumerated() { results[i + 1] = items[id] ?? [] }
        return Citations.Sources(cards: cards, results: results)
    }

    // MARK: 起名

    /// 第一个回答出来后起一个 12 字（英文 6 个词）以内的名字。起不出来就还叫「新讨论」，不打扰。
    /// 和跑一轮分开：答完就能接着问，不用等起名
    public func nameIfNeeded(_ discussion: Int64) async {
        guard (try? await store.discussion(discussion))??.name == nil, let events = try? await store.events(of: discussion),
              case .question(let asked)? = events.last(where: { if case .question = $0.what { true } else { false } })?.what,
              case .answer(let answer)? = events.last(where: { if case .answer = $0.what { true } else { false } })?.what else { return }
        struct Reply: Decodable { var name: String }
        let prompt = """
            给下面这段讨论起一个名字，\(Writing.length(12))以内的\(Writing.language)，说清在讨论什么，不加引号和标点。
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
