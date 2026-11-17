import Foundation
import Library

/// Where a card goes when put on a board: that belongs to the Canvas module, which Intelligence can't see, so only the protocol is written here; the app implements it and hands it to sorting
public protocol Placer: Sendable {
    /// One placement (position, size) per target board; sorting does the writing
    func placements(for card: Int64, into boards: [Sorter.Scored]) async throws -> [Placement]
}

/// Sorting: after a card's understanding is done, decide which other boards it should go on.
/// First pick up to 8 candidate boards locally with embeddings, then ask Jev about every candidate in one request "does it belong here"; only those whose probability reaches the placement line are placed.
/// Where on the board is computed by Placer; the writing happens here.
/// The queue copies the understanding queue: each time it's woken, pick out the cards ready for sorting and do them; what's unfinished at quit is picked up next time
public actor Sorter {
    let store: Store
    let gateway: Gateway
    let placer: any Placer
    /// Called once when a card was put on other boards; the app uses it to show a notice and refresh the canvas
    let placed: @Sendable ([Placement]) -> Void
    /// Placement line: only placed when Jev's probability of "belongs on this board" reaches this line
    let line: Double
    /// Rule embeddings, cached by "embedding model + rule text": there are only a few rules, each takes milliseconds to compute locally, not worth storing in the library
    private var ruleVectors: [String: [Float]] = [:]
    private var running = false
    /// Something new happened while working: look again after this round
    private var dirty = false

    /// Line measured on a real library: in both test groups wrong placements stay under 2%, and about half of the cards that belong get placed
    public static let defaultLine = 0.85
    /// Take the top few boards by card comparison and the top few by rule comparison
    static let byCards = 5, byRule = 3
    /// Compare with the few most similar cards on the board; these are also attached when asking Jev
    static let nearest = 3
    /// When one request hangs the whole sorting queue stops, so it has a time limit
    static let timeout = 10.0

    public init(store: Store, gateway: Gateway, placer: any Placer, line: Double = Sorter.defaultLine, placed: @escaping @Sendable ([Placement]) -> Void) {
        self.store = store
        self.gateway = gateway
        self.placer = placer
        self.line = line
        self.placed = placed
    }

    /// Conclusion for one candidate board: Jev's probability of "belongs", and which card on the board to place it near (nil for an empty board with only rules)
    public struct Scored: Sendable, Equatable {
        public var board: Int64
        public var near: Int64?
        public var probability: Double
    }

    // MARK: Queue

    /// A card's understanding finished, a key was entered, the network came back, or "Sort These Cards" was clicked: look again at which cards can be sorted
    public nonisolated func kick() {
        Task(priority: .utility) { await self.run() }
    }

    /// Work until nothing is left to sort (tests wait on this directly)
    public func run() async {
        dirty = true
        guard !running else { return }
        running = true
        defer { running = false }
        while dirty {
            dirty = false
            await pass()
        }
    }

    /// Sortable cards go newest collected first, judged and written one by one. The snapshot is read once per round, and placed cards are noted in it as we go.
    /// If it can't be judged (Jev unavailable, error, timeout) or writing fails, the card stays unsorted and this round stops until woken next time
    private func pass() async {
        guard gateway.canSort, let model = gateway.embeddingModel,
              let cards = try? await store.unsortedCards(), let vectors = try? await store.vectorBases() else { return }
        let ready = cards.filter { Understander.isUnderstood($0, vector: vectors[$0.id!], model: model) }.sorted { $0.collectedAt > $1.collectedAt }
        guard !ready.isEmpty, let rows = try? await store.searchRows(), let boards = try? await store.boards(),
              let entries = try? await store.boardEntries() else { return }
        var snapshot = Snapshot(cards: rows.map { Searcher.searchCard($0, model: model) }, boards: boards, entries: entries, model: model)
        for card in ready.map({ $0.id! }) {
            // One round may sort dozens of cards: if a board was created or rules changed meanwhile, take a new snapshot and start over
            guard !dirty else { return }
            guard let scored = await score(card, in: snapshot) else { return }
            let picked = Self.pick(scored, line: line, inner: snapshot.inner)
            // Mark as sorted whether placed or not, written in one go
            guard let written = try? await store.recordSorting(card, placements: placer.placements(for: card, into: picked)) else { return }
            if !written.isEmpty { placed(written) }
            for p in picked { snapshot.members[p.board, default: []].insert(card) }
        }
    }

    // MARK: Snapshot

    /// Library snapshot for judging: cards (embeddings only if computed by the current model), boards, and which cards sit directly on each board
    struct Snapshot: Sendable {
        let model: String
        let cards: [Int64: SearchCard]
        let boards: [Int64: Board]
        var members: [Int64: Set<Int64>]
        /// Inner boards each board can reach through links (any depth, excluding itself)
        let inner: [Int64: Set<Int64>]

        init(cards: [SearchCard], boards: [Board], entries: [Int64: Set<Int64>], model: String) {
            self.model = model
            self.cards = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            self.boards = Dictionary(uniqueKeysWithValues: boards.map { ($0.id!, $0) })
            members = [:]
            for card in cards { for board in card.boards { members[board, default: []].insert(card.id) } }
            inner = entries.mapValues { direct in
                var reached = Set<Int64>(), pending = Array(direct)
                while let next = pending.popLast() {
                    if reached.insert(next).inserted { pending += entries[next] ?? [] }
                }
                return reached
            }
        }

        /// The card is on this board or any of its inner boards at any depth
        func holds(_ board: Int64, _ card: Int64) -> Bool {
            ([board] + (inner[board] ?? [])).contains { members[$0]?.contains(card) == true }
        }

        /// Cards on the board that have embeddings, by similarity to vector from high to low
        func nearest(_ board: Int64, to vector: [Float]) -> [(card: SearchCard, vector: [Float])] {
            (members[board] ?? []).compactMap { id in cards[id].flatMap { c in c.vector.map { (c, $0) } } }
                .sorted { dot($0.vector, vector) > dot($1.vector, vector) }
        }
    }

    // MARK: Judging

    /// Pick candidates, ask Jev, and give each candidate board's probability; empty when there are no candidates. nil means it can't be judged
    func score(_ id: Int64, in s: Snapshot) async -> [Scored]? {
        guard let card = s.cards[id], let vector = card.vector else { return nil }
        // Participating boards: auto-sorting on, the card not on it or its inner boards, with at least one card or a rule
        var pools: [Pool] = []
        for board in s.boards.values where board.autoSort && !s.holds(board.id!, id) {
            let cards = s.nearest(board.id!, to: vector).map(\.vector)
            var rule: [Float]?
            if let text = board.rule {
                guard let v = await ruleVector(text, model: s.model) else { return nil }
                rule = v
            }
            if !cards.isEmpty || rule != nil { pools.append(Pool(id: board.id!, cards: cards, rule: rule)) }
        }
        let candidates = Self.candidates(vector, among: pools).map { ($0, Array(s.nearest($0, to: vector).prefix(Self.nearest).map(\.card))) }
        guard !candidates.isEmpty else { return [] }

        let questions = candidates.map { Self.question(s.boards[$0]!, examples: $1) }
        let (facts, gateway): (Facts, Gateway) = ([("新卡片", card.brief)], gateway)
        guard let verdicts = await within(Self.timeout, { try await gateway.judge(facts, questions, fallback: false) }) else { return nil }
        return zip(candidates, verdicts).map { Scored(board: $0.0, near: $0.1.first?.id, probability: Self.probability($1)) }
    }

    private func ruleVector(_ rule: String, model: String) async -> [Float]? {
        let key = model + "\u{1F}" + rule
        if let v = ruleVectors[key] { return v }
        // Rules are computed as if they were a sentence in search
        guard let v = try? await gateway.embed(rule, as: .query) else { return nil }
        ruleVectors[key] = v
        return v
    }

    /// A board taking part in sorting: embeddings of its cards and of its rules
    struct Pool {
        var id: Int64
        var cards: [[Float]]
        var rule: [Float]?
    }

    /// Two lists taken separately, then merged and deduplicated: top 5 by cards (average similarity to the 3 most similar cards on the board, or all if fewer than 3), top 3 by rules.
    /// Not combined into one score: "card to card" and "rule to card" similarities aren't on the same ruler, and boards with only rules would be systematically crowded out. No minimum score either; low-similarity ones are left for Jev to reject
    static func candidates(_ vector: [Float], among pools: [Pool]) -> [Int64] {
        func top(_ scored: [(id: Int64, score: Float)], _ n: Int) -> [Int64] {
            scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.prefix(n).map(\.id)
        }
        let byCards = top(pools.filter { !$0.cards.isEmpty }.map { pool in
            let nearest = pool.cards.map { dot($0, vector) }.sorted(by: >).prefix(nearest)
            return (pool.id, nearest.reduce(0, +) / Float(nearest.count))
        }, Self.byCards)
        let byRule = top(pools.compactMap { pool in pool.rule.map { (pool.id, dot($0, vector)) } }, Self.byRule)
        return byCards + byRule.filter { !byCards.contains($0) }
    }

    /// The current judging API only gives the most likely answer and its probability: when it answers "no", the probability of belonging is 1 minus that
    static func probability(_ v: Verdict) -> Double { v.yes ? v.confidence : 1 - v.confidence }

    /// Each board is compared with the placement line on its own, so a card can go on several. With nesting, only the innermost: if B is inside A (any depth) and B will get it, A doesn't
    static func pick(_ scored: [Scored], line: Double, inner: [Int64: Set<Int64>]) -> [Scored] {
        let passed = scored.filter { $0.probability >= line }
        let boards = Set(passed.map(\.board))
        return passed.filter { inner[$0.board, default: []].isDisjoint(with: boards) }
    }

    /// One question per candidate board: board name, rules, and the few cards on the board most like the new card.
    /// Asking "does it belong to this board's topic" suits the judge model better than "should it go in": on a real library, with no more wrong placements, the share of belonging cards placed rose from 36% to 47%
    static func question(_ board: Board, examples: [SearchCard]) -> Question {
        var text = "用户的画板「\(board.name)」收同一类主题的卡片。这张新卡片属于这个画板的主题吗？"
        if let rule = board.rule { text += "\n这个画板收：\(rule)" }
        if !examples.isEmpty { text += "\n画板里和它最像的几张卡：\n" + examples.map { "- " + $0.brief }.joined(separator: "\n") }
        return Question(text, .yesNo)
    }
}
