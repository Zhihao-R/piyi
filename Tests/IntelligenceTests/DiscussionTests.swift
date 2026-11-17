import Testing
import Foundation
import Synchronization
@testable import Intelligence
@testable import Library

/// A fake chat provider that hands out pre-written answers in order, recording what it receives each turn
final class FakeConversation: Conversation, Sendable {
    let name = "假对话", isReady = true
    let replies: Mutex<[[ChatChunk]]>
    let chats = Mutex<[Chat]>([])

    init(_ replies: [[ChatChunk]]) { self.replies = Mutex(replies) }

    func contextLength() async -> Int? { 100_000 }

    func converse(_ chat: Chat) -> AsyncThrowingStream<ChatChunk, Error> {
        chats.withLock { $0.append(chat) }
        let reply = replies.withLock { $0.isEmpty ? [] : $0.removeFirst() }
        return AsyncThrowingStream { c in
            for chunk in reply { c.yield(chunk) }
            c.finish()
        }
    }
}

/// A tool that always returns the same sentence
struct EchoTool: Tool {
    var spec: ToolSpec { ToolSpec(name: "echo", description: "", parameters: "{}") }
    let title = "回声", nature = ToolNature.reading
    func run(_ arguments: String, desk: Set<Int64>) async throws -> ToolOutput { ToolOutput(text: "读回来了", detail: arguments, items: ["第一项", "第二项"]) }
}

/// A tool that takes a while to run: stop is pressed while it's running
struct SlowTool: Tool {
    var spec: ToolSpec { ToolSpec(name: "slow", description: "", parameters: "{}") }
    let title = "慢", nature = ToolNature.reading
    func run(_ arguments: String, desk: Set<Int64>) async throws -> ToolOutput {
        try? await Task.sleep(for: .seconds(1))
        return ToolOutput(text: "半截", detail: "")
    }
}

@Suite struct CitationTests {
    let sources = Citations.Sources(
        cards: [12: (title: "卡十二", passages: [Passage(part: .body, number: 1, text: "第一段"), Passage(part: .transcript, number: 1, text: "00:05 说的话", seconds: 5)]),
                13: (title: "图片", passages: [])],
        results: [1: ["网页摘录"]])

    @Test func keepsValidAndDropsTheRest() {
        let answer = Citations.check("甲[c12·p1]乙[c12·t1]丙[c13]丁[r1·1]。错的：[c99·p1][c12·p9][r1·5][c12·x1][c12·p1]", against: sources)
        #expect(answer.text == "甲[c12·p1]乙[c12·t1]丙[c13]丁[r1·1]。错的：[c12·p1]")
        #expect(answer.citations.map(\.ref) == ["c12·p1", "c12·t1", "c13", "r1·1"])
        #expect(answer.citations.map(\.quote) == ["第一段", "00:05 说的话", "图片", "网页摘录"])
        #expect(answer.citations[1].seconds == 5)
    }

    /// Several references in one pair of brackets: split them; if any one is invalid, drop the whole thing
    @Test func splitsListsInOneBracket() {
        #expect(Citations.check("甲[c12·p1, c12·t1]", against: sources).text == "甲[c12·p1][c12·t1]")
        #expect(Citations.check("甲[c12·p1, c99]", against: sources).text == "甲")
        #expect(Citations.check("候选 c99（[c99]）。", against: sources).text == "候选 c99。")
        #expect(Citations.check("压抑 [c99]。留着 [c13]。", against: sources).text == "压抑。留着 [c13]。")
        // Images have no paragraphs: even with a paragraph number, it counts as the whole image
        #expect(Citations.check("图里写着[c13·p2]", against: sources).text == "图里写着[c13]")
    }

    /// Halfway through generating: finished citations show as small numbers, an unfinished one at the end stays hidden for now
    @Test func streamingHidesUnfinishedCitation() {
        #expect(Citations.pieces("甲[c12·p1]乙[c12·", streaming: true) == [.text("甲"), .cite("c12·p1"), .text("乙")])
        #expect(Citations.pieces("数组 a[0", streaming: false) == [.text("数组 a[0")])
        #expect(Citations.plain("甲[c12·p1]乙") == "甲乙")
    }
}

@Suite struct RecipeTests {
    func desk(_ id: Int64, _ text: String, trashed: Bool = false) -> DeskCard {
        var card = Card(kind: .text)
        (card.id, card.text, card.trashedAt) = (id, text, trashed ? .now : nil)
        return DeskCard(card: card, passages: Passages.of(card))
    }

    func events(_ list: [Happening]) -> [DiscussionEvent] {
        list.enumerated().map { DiscussionEvent(discussion: 1, seq: $0.offset + 1, at: .distantPast, what: $0.element) }
    }

    /// The same record and table build the same messages; cards put on the table after the conversation starts go into the record, the opening table stays the same, and the cache still hits
    @Test func placingAppendsWithoutTouchingTheOpening() {
        let recipe = WholeText()
        let before = recipe.chat(desk: [desk(1, "甲")], events: events([.question("问"), .answer(Answer(text: "答", citations: []))]), tools: [])
        #expect(before == recipe.chat(desk: [desk(1, "甲")], events: events([.question("问"), .answer(Answer(text: "答", citations: []))]), tools: []))
        let after = recipe.chat(desk: [desk(1, "甲"), desk(2, "乙")], events: events([
            .question("问"), .answer(Answer(text: "答", citations: [])), .placed(CardMention(card: 2, title: "乙")), .question("再问"),
        ]), tools: [])
        #expect(Array(after.messages.prefix(2)) == Array(before.messages.prefix(2)))
        #expect(after.messages.last!.text.contains("（引用 · 乙）") && after.messages.last!.text.contains("p1 乙"))
        #expect(after.stableThrough == Chat.Position(message: 1, part: 0))
    }

    /// Taking a card off the table: rebuild everything, the removed card isn't in the opening table; cards in the trash aren't put in either
    @Test func removingRebuildsAndTrashedIsLeftOut() {
        let chat = WholeText().chat(desk: [desk(1, "甲"), desk(2, "乙"), desk(3, "丙", trashed: true)], events: events([
            .question("问"), .placed(CardMention(card: 2, title: "乙")), .removed(CardMention(card: 4, title: "丁")), .question("再问"),
        ]), tools: [])
        let opening = chat.messages[1].text
        #expect(opening.contains("p1 甲") && opening.contains("p1 乙") && !opening.contains("丙"))
        #expect(chat.messages.count == 2)
        #expect(chat.messages[1].text.contains("（取消引用 · 丁）"))
    }

    /// Gray text for cards put on the table while waiting for a tool result moves after the result; calls that never got a result aren't passed to the model
    @Test func toolResultsFollowTheirCalls() {
        let call = ToolCall(id: "a", name: "echo", arguments: "{}"), lost = ToolCall(id: "b", name: "echo", arguments: "{}")
        let chat = WholeText().chat(desk: [], events: events([
            .question("问"), .calls(said: "", [call, lost]), .placed(CardMention(card: 9, title: "九")),
            .result(ToolResult(call: "a", label: "", text: "结果")),
        ]), tools: [])
        #expect(chat.messages.map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(chat.messages[2].calls == [call])
    }
}

@Suite struct KernelTests {
    func events(_ list: [Happening]) -> [DiscussionEvent] {
        list.enumerated().map { DiscussionEvent(discussion: 1, seq: $0.offset + 1, at: .distantPast, what: $0.element) }
    }

    /// After an interruption at any step, the same next step is recognized from the record
    @Test func nextStepComesFromTheRecord() {
        let call = ToolCall(id: "a", name: "echo", arguments: "{}")
        #expect(DiscussionKernel.next(events([])) == .idle)
        #expect(DiscussionKernel.next(events([.question("问")])) == .ask(round: 0))
        #expect(DiscussionKernel.next(events([.question("问"), .calls(said: "", [call])])) == .runTools([call], round: 1))
        #expect(DiscussionKernel.next(events([.question("问"), .calls(said: "", [call]), .result(ToolResult(call: "a", label: "", text: ""))])) == .ask(round: 1))
        #expect(DiscussionKernel.next(events([.question("问"), .answer(Answer(text: "", citations: []))])) == .idle)
        // Asked again before the answer finished: answer the new one
        #expect(DiscussionKernel.next(events([.question("问"), .question("再问")])) == .ask(round: 0))
    }

    /// One turn: call a tool → result written to the record → answer, saved only after citations are checked
    @Test func runsToolThenAnswers() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let card = try await store.createNote("桌上的话", on: board, frame: .zero).cardID!
        let id = try await store.startDiscussion(desk: [card], opening: [.question("问")])
        let fake = FakeConversation([
            [.call(ToolCall(id: "x", name: "echo", arguments: "查")), .done(ChatUsage(input: 10, cost: 0.01))],
            [.text("依据桌上[c\(card)·p1]和工具[r1·2]"), .text("，瞎编[c\(card)·p7]"), .done(ChatUsage(input: 20, cached: 15, cost: 0.02))],
        ])
        let kernel = DiscussionKernel(store: store, gateway: Gateway(embedder: nil, generators: [], conversers: [fake]), tools: [EchoTool()])
        let report = try await kernel.run(id)
        let events = try await store.events(of: id)
        #expect(events.map { $0.what.kind } == ["question", "calls", "result", "answer"])
        guard case .result(let result) = events[2].what, case .answer(let answer) = events[3].what else { Issue.record("记录不对"); return }
        #expect(result.label == "回声：查")
        #expect(answer.text == "依据桌上[c\(card)·p1]和工具[r1·2]，瞎编")
        #expect(answer.citations.map(\.quote) == ["桌上的话", "第二项"])
        #expect(report.usage.cost == 0.03 && report.usage.cached == 15)
        // What's sent to the model in the second turn includes the tool call and result
        #expect(fake.chats.withLock { $0[1].messages.map(\.role) } == [.system, .user, .assistant, .tool])
    }

    /// The tool-turn limit is reached: the model may only answer with what it already has
    @Test func toolRoundsAreCapped() async throws {
        let store = try temporaryStore()
        let id = try await store.startDiscussion(desk: [], opening: [.question("问")])
        let call = { (i: Int) in [ChatChunk.call(ToolCall(id: "c\(i)", name: "nope", arguments: "{}")), .done(ChatUsage())] }
        let fake = FakeConversation((0..<DiscussionKernel.toolRounds).map(call) + [[.text("只好直说"), .done(ChatUsage())]])
        let kernel = DiscussionKernel(store: store, gateway: Gateway(embedder: nil, generators: [], conversers: [fake]), tools: [])
        try await kernel.run(id)
        #expect(fake.chats.withLock { $0.last!.toolsAllowed } == false)
        let events = try await store.events(of: id)
        // An unknown tool returns "failed"
        if case .result(let r) = events[2].what { #expect(r.failed && r.label == "nope没成功") }
        #expect(events.last?.what == .answer(Answer(text: "只好直说", citations: [])))
    }

    /// A tool stopped midway: no partial result is written, and the next retry runs it again
    @Test func stoppingDuringToolLeavesNoResult() async throws {
        let store = try temporaryStore()
        let id = try await store.startDiscussion(desk: [], opening: [.question("问")])
        let fake = FakeConversation([[.call(ToolCall(id: "s", name: "slow", arguments: "{}")), .done(ChatUsage())]])
        let kernel = DiscussionKernel(store: store, gateway: Gateway(embedder: nil, generators: [], conversers: [fake]), tools: [SlowTool()])
        let run = Task { try await kernel.run(id) }
        try await Task.sleep(for: .milliseconds(300))
        run.cancel()
        _ = await run.result
        let events = try await store.events(of: id)
        #expect(events.map { $0.what.kind } == ["question", "calls"])
        #expect(DiscussionKernel.next(events) == .runTools([ToolCall(id: "s", name: "slow", arguments: "{}")], round: 1))
    }
}
