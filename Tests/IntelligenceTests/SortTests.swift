import Testing
import Foundation
import Synchronization
@testable import Intelligence
@testable import Library

/// A fake judgment provider with preset answers: whichever board name the question contains, it answers with that board's preset; anything not preset is answered "no", confidence 0.9
final class FakeJudge: Judgment, Sendable {
    let name = "假判断", seesImages = false, sureEnough = 0.85
    let answers: [String: Verdict]
    let fails: Bool
    let asked = Mutex<[String]>([])
    var isReady: Bool { true }

    init(_ answers: [String: Verdict] = [:], fails: Bool = false) {
        self.answers = answers
        self.fails = fails
    }

    func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict] {
        asked.withLock { $0 += questions.map(\.text) }
        if fails { throw MalformedReply() }
        return questions.map { q in answers.first { q.text.contains("「\($0.key)」") }?.value ?? Verdict(choice: 1, confidence: 0.9) }
    }
}

/// Rule vectors are given as preset; card vectors in the tests are written straight into the snapshot
struct FakeRuleEmbedder: Embedding {
    let name = "假本机", isReady = true, model = "fake-embedding"
    let vectors: [String: [Float]]
    func embed(_ text: String, as role: EmbeddingRole) async throws -> [Float] { vectors[text] ?? [0, 0, 1] }
}

/// Placement for tests: everything goes at the origin
struct OriginPlacer: Placer {
    func placements(for card: Int64, into boards: [Sorter.Scored]) async throws -> [Placement] {
        boards.map { Placement(boardID: $0.board, frame: .zero, z: 0) }
    }
}

@Suite struct Sorting {
    static func sorter(_ gateway: Gateway) throws -> Sorter {
        Sorter(store: try temporaryStore(), gateway: gateway, placer: OriginPlacer()) { _ in }
    }

    static func gateway(_ judge: FakeJudge, rules: [String: [Float]] = [:], generators: [any Generation] = []) throws -> Gateway {
        Gateway(embedder: FakeRuleEmbedder(vectors: rules), generators: generators, judges: [judge])
    }

    /// A card: which boards it's on, and its vector (nil means not computed yet)
    static func card(_ id: Int64, _ vector: [Float]?, in boards: Set<Int64> = []) -> SearchCard {
        SearchCard(id: id, kind: .text, collectedAt: .now, text: "", colors: nil, vector: vector, boards: boards, brief: "卡\(id)")
    }

    static func board(_ id: Int64, _ name: String, rule: String? = nil, autoSort: Bool = true) -> Board {
        var b = Board(name: name)
        b.id = id
        b.rule = rule
        b.autoSort = autoSort
        return b
    }

    static func snapshot(_ cards: [SearchCard], _ boards: [Board], entries: [Int64: Set<Int64>] = [:]) -> Sorter.Snapshot {
        Sorter.Snapshot(cards: cards, boards: boards, entries: entries, model: "fake-embedding")
    }

    static let yes = Verdict(choice: 0, confidence: 0.95)

    // MARK: Picking candidates

    /// Card-to-card similarity is generally higher than rule-to-card: with one combined score, boards that only have a rule never make it in; taking them separately lets them
    @Test func ruleListIsTakenSeparately() {
        let v: [Float] = [1, 0]
        let pools = (1...6).map { Sorter.Pool(id: Int64($0), cards: [[0.9, 0.1]], rule: nil) } + [Sorter.Pool(id: 7, cards: [], rule: [0.3, 0.95])]
        let picked = Sorter.candidates(v, among: pools)
        #expect(picked.count == 6)
        #expect(picked.contains(7))
    }

    /// Compare only with the 3 most similar cards; with fewer than 3, use them all
    @Test func comparesNearestThreeOrAll() {
        let v: [Float] = [1, 0]
        // Board 1: one very similar, three dissimilar, average dragged down; board 2: two moderately similar, both used
        let pools = [Sorter.Pool(id: 1, cards: [[1, 0], [0, 1], [0, 1], [0, 1]], rule: nil),
                     Sorter.Pool(id: 2, cards: [[0.5, 0.5], [0.5, 0.5]], rule: nil)]
        #expect(Sorter.candidates(v, among: pools) == [2, 1])
        // Board 1 changed to three very similar plus a pile of dissimilar ones: only the 3 most similar are taken, and it ranks first
        let crowded = [Sorter.Pool(id: 1, cards: [[1, 0], [1, 0], [1, 0]] + Array(repeating: [0, 1], count: 10), rule: nil), pools[1]]
        #expect(Sorter.candidates(v, among: crowded) == [1, 2])
    }

    @Test func atMostFiveByCardsAndThreeByRule() {
        let pools = (1...10).map { Sorter.Pool(id: Int64($0), cards: [[Float($0), 1]], rule: [Float($0), 1]) }
        let picked = Sorter.candidates([1, 0], among: pools)
        #expect(picked == [10, 9, 8, 7, 6])
        let rulesOnly = (1...10).map { Sorter.Pool(id: Int64($0), cards: [], rule: [Float($0), 1]) }
        #expect(Sorter.candidates([1, 0], among: rulesOnly) == [10, 9, 8])
    }

    // MARK: Probability and placement threshold

    @Test func noAnswerMeansOneMinus() {
        #expect(Sorter.probability(Verdict(choice: 0, confidence: 0.9)) == 0.9)
        #expect(abs(Sorter.probability(Verdict(choice: 1, confidence: 0.8)) - 0.2) < 1e-9)
    }

    @Test func eachBoardMeetsTheLineOnItsOwn() {
        let scored = [Sorter.Scored(board: 1, near: 11, probability: 0.9), Sorter.Scored(board: 2, near: 12, probability: 0.86),
                      Sorter.Scored(board: 3, near: nil, probability: 0.84)]
        #expect(Sorter.pick(scored, line: 0.85, inner: [:]) == Array(scored.prefix(2)))
    }

    // MARK: Nesting

    @Test func onlyInnermostOfNestedBoards() async throws {
        let judge = FakeJudge(["外": Self.yes, "中": Self.yes, "里": Self.yes])
        let snapshot = Self.snapshot([Self.card(1, [1, 0]), Self.card(2, [1, 0], in: [10]), Self.card(3, [1, 0], in: [20]), Self.card(4, [1, 0], in: [30])],
                                     [Self.board(10, "外"), Self.board(20, "中"), Self.board(30, "里")], entries: [10: [20], 20: [30]])
        let sorter = try Self.sorter(try Self.gateway(judge))
        let scored = try #require(await sorter.score(1, in: snapshot))
        #expect(Set(scored.map(\.board)) == [10, 20, 30])
        #expect(Sorter.pick(scored, line: 0.85, inner: snapshot.inner).map(\.board) == [30])
    }

    @Test func outerBoardSkippedWhenCardIsInside() async throws {
        let judge = FakeJudge(["外": Self.yes])
        let snapshot = Self.snapshot([Self.card(1, [1, 0], in: [30]), Self.card(2, [1, 0], in: [10])],
                                     [Self.board(10, "外"), Self.board(20, "中"), Self.board(30, "里")], entries: [10: [20], 20: [30]])
        let sorter = try Self.sorter(try Self.gateway(judge))
        #expect(try #require(await sorter.score(1, in: snapshot)).isEmpty)
        #expect(judge.asked.withLock { $0 }.isEmpty)
    }

    // MARK: Participating boards

    @Test func closedEmptyAndRuleOnlyBoards() async throws {
        let judge = FakeJudge(["规则": Self.yes])
        let snapshot = Self.snapshot([Self.card(1, [1, 0]), Self.card(2, [1, 0], in: [10])],
                                     [Self.board(10, "关了", autoSort: false), Self.board(20, "空的"), Self.board(30, "规则", rule: "收和 1 有关的")])
        let sorter = try Self.sorter(try Self.gateway(judge, rules: ["收和 1 有关的": [1, 0]]))
        let scored = try #require(await sorter.score(1, in: snapshot))
        #expect(scored == [.init(board: 30, near: nil, probability: 0.95)])
        let question = try #require(judge.asked.withLock { $0 }.first)
        #expect(question.contains("这个画板收：收和 1 有关的"))
    }

    @Test func questionCarriesNearestThree() async throws {
        let judge = FakeJudge()
        let cards = [Self.card(1, [1, 0])] + (2...6).map { Self.card(Int64($0), [Float(7 - $0), Float($0)], in: [10]) } + [Self.card(7, nil, in: [10])]
        let snapshot = Self.snapshot(cards, [Self.board(10, "甲")])
        let sorter = try Self.sorter(try Self.gateway(judge))
        let scored = try #require(await sorter.score(1, in: snapshot))
        #expect(scored.first?.near == 2)
        let question = try #require(judge.asked.withLock { $0 }.first)
        #expect(question.contains("卡2") && question.contains("卡3") && question.contains("卡4") && !question.contains("卡5") && !question.contains("卡7"))
    }

    // MARK: Jev only

    /// When the dedicated judgment provider errors, the gateway falls back to the generation model; sorting doesn't accept that answer and treats it as a failure
    @Test func generatedAnswerCountsAsFailure() async throws {
        let judge = FakeJudge(fails: true), cloud = FakeCloud()
        let snapshot = Self.snapshot([Self.card(1, [1, 0]), Self.card(2, [1, 0], in: [10])], [Self.board(10, "甲")])
        let sorter = try Self.sorter(try Self.gateway(judge, generators: [cloud]))
        #expect(await sorter.score(1, in: snapshot) == nil)
        #expect(cloud.calls.withLock { $0 }.isEmpty)
    }

    @Test func noVectorYetMeansNotNow() async throws {
        let snapshot = Self.snapshot([Self.card(1, nil), Self.card(2, [1, 0], in: [10])], [Self.board(10, "甲")])
        let sorter = try Self.sorter(try Self.gateway(FakeJudge()))
        #expect(await sorter.score(1, in: snapshot) == nil)
    }

    // MARK: Queue

    /// Collects a card that's only in the library (not placed on a board)
    static func collect(_ store: Store, _ text: String, partial: Partial? = nil) async throws -> Int64 {
        var m = Material(kind: .text)
        m.text = text
        m.partial = partial
        let id = try await store.placeholder(.text, on: nil, frame: .zero)
        _ = try await store.fill(id, with: m)
        return id
    }

    /// Only sortable cards are sorted: understanding done, body completion finished, not a partial card. Placements made get the newly-added mark, and the card is marked sorted
    @Test func queueSortsOnlyReadyCards() async throws {
        let store = try temporaryStore()
        let judge = FakeJudge(["配色": Self.yes])
        let gateway = Gateway(embedder: FakeLocalEmbedder(), generators: [FakeCloud()], judges: [judge])
        let colors = try await store.createBoard("配色").id!
        let inside = try await Self.collect(store, "灰调里的绿")
        try await store.place(card: inside, on: colors, frame: .zero)
        let ready = try await Self.collect(store, "莫兰迪的配色")
        let partial = try await Self.collect(store, "残缺的", partial: .offline)
        let bodyPending = try await Self.collect(store, "还在转录的")
        let notUnderstood = try await Self.collect(store, "没理解完的")
        await Understander(store: store, gateway: gateway) {}.run()
        try await store.forgetUnderstanding([notUnderstood])
        for id in [inside, ready, partial, notUnderstood] { try await store.markBodyCompleted(id) }

        await Sorter(store: store, gateway: gateway, placer: OriginPlacer()) { _ in }.run()
        let placed = try await store.items(on: colors).filter { $0.placement.cardID == ready }
        #expect(placed.count == 1 && placed[0].placement.unseen)
        #expect(try await store.card(ready)?.sorted == true)
        // The card already in "配色" has no other candidates: it was judged, nothing is placed, and it's still marked sorted
        #expect(try await store.card(inside)?.sorted == true)
        for id in [partial, bodyPending, notUnderstood] { #expect(try await store.card(id)?.sorted == false) }
    }

    /// Jev errors: the card stays unsorted and is sorted next time
    @Test func failedJudgmentLeavesCardUnsorted() async throws {
        let store = try temporaryStore()
        let gateway = Gateway(embedder: FakeLocalEmbedder(), generators: [FakeCloud()], judges: [FakeJudge(fails: true)])
        let colors = try await store.createBoard("配色").id!
        let inside = try await Self.collect(store, "灰调里的绿"), card = try await Self.collect(store, "莫兰迪的配色")
        try await store.place(card: inside, on: colors, frame: .zero)
        await Understander(store: store, gateway: gateway) {}.run()
        for id in [inside, card] { try await store.markBodyCompleted(id) }
        await Sorter(store: store, gateway: gateway, placer: OriginPlacer()) { _ in }.run()
        #expect(try await store.card(card)?.sorted == false)
        #expect(try await store.items(on: colors).count == 1)
    }
}
