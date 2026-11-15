import Foundation
import Library

/// 卡放进画板时摆在哪：这归画布块，智能块看不见，所以这里只写协议、由 App 实现后交给分拣
public protocol Placer: Sendable {
    /// 每个目标画板一条摆放（位置、大小），写入由分拣来做
    func placements(for card: Int64, into boards: [Sorter.Scored]) async throws -> [Placement]
}

/// 分拣：一张卡理解做完后，判断还要放进哪些画板。
/// 先在本机用向量挑出最多 8 个候选画板，再一次请求问 Jev 每个候选「是不是属于这里」，概率到放进线的才放。
/// 摆在画板哪里由 Placer 算，写入在这里。
/// 队列照抄理解队列：每次被叫醒，把能分拣的卡挑出来做，退出时没做完的下次接着做
public actor Sorter {
    let store: Store
    let gateway: Gateway
    let placer: any Placer
    /// 放进了别的画板时调一次，App 据此弹提示、刷新画布
    let placed: @Sendable ([Placement]) -> Void
    /// 放进线：Jev 判「属于这个画板」的概率到这条线才放
    let line: Double
    /// 规则的向量，按「向量模型 + 规则文字」缓存：规则只有几条，在本机算一条几毫秒，不值得存进资料库
    private var ruleVectors: [String: [Float]] = [:]
    private var running = false
    /// 正在做的时候又有新情况：这一轮做完再看一遍
    private var dirty = false

    /// 在真实资料库上测出来的线：两组测试里放错都不超过 2%，该放的放进了一半左右
    public static let defaultLine = 0.85
    /// 按卡片比取前几个画板、按规则比取前几个
    static let byCards = 5, byRule = 3
    /// 和画板里最像的几张卡比；问 Jev 时也附这几张
    static let nearest = 3
    /// 一次请求卡住时整个分拣队列会停住，所以限时
    static let timeout = 10.0

    public init(store: Store, gateway: Gateway, placer: any Placer, line: Double = Sorter.defaultLine, placed: @escaping @Sendable ([Placement]) -> Void) {
        self.store = store
        self.gateway = gateway
        self.placer = placer
        self.line = line
        self.placed = placed
    }

    /// 一个候选画板的结论：Jev 判「属于」的概率，以及靠近画板里的哪张卡摆（只写了规则的空画板为 nil）
    public struct Scored: Sendable, Equatable {
        public var board: Int64
        public var near: Int64?
        public var probability: Double
    }

    // MARK: 队列

    /// 理解做完一张卡、填了密钥、网络恢复、点了「分拣这些卡」：重新看一遍哪些卡能分拣
    public nonisolated func kick() {
        Task(priority: .utility) { await self.run() }
    }

    /// 做到没有能分拣的为止（测试里直接等它）
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

    /// 能分拣的卡按收集时间从新到旧，逐张判断、写入。快照每轮读一次，放进去的卡随手记进快照。
    /// 判断不了（Jev 不可用、出错、超时）或写入失败，这张卡保持未分拣，这一轮停下，等下次被叫醒
    private func pass() async {
        guard gateway.canJudge, let model = gateway.embeddingModel,
              let cards = try? await store.unsortedCards(), let vectors = try? await store.vectorBases() else { return }
        let ready = cards.filter { Understander.isUnderstood($0, vector: vectors[$0.id!], model: model) }.sorted { $0.collectedAt > $1.collectedAt }
        guard !ready.isEmpty, let rows = try? await store.searchRows(), let boards = try? await store.boards(),
              let entries = try? await store.boardEntries() else { return }
        var snapshot = Snapshot(cards: rows.map { Searcher.searchCard($0, model: model) }, boards: boards, entries: entries, model: model)
        for card in ready.map({ $0.id! }) {
            // 一轮可能要分几十张：期间建了画板、改了规则，换新快照重来
            guard !dirty else { return }
            guard let scored = await score(card, in: snapshot) else { return }
            let picked = Self.pick(scored, line: line, inner: snapshot.inner)
            // 放没放进去都标成已分拣，一次写完
            guard let written = try? await store.recordSorting(card, placements: placer.placements(for: card, into: picked)) else { return }
            if !written.isEmpty { placed(written) }
            for p in picked { snapshot.members[p.board, default: []].insert(card) }
        }
    }

    // MARK: 快照

    /// 判断要用的资料库快照：卡片（向量是当前模型算的才有）、画板、每个画板直接放着哪些卡
    struct Snapshot: Sendable {
        let model: String
        let cards: [Int64: SearchCard]
        let boards: [Int64: Board]
        var members: [Int64: Set<Int64>]
        /// 每个画板经入口能到达的里层画板（隔几层也算，不含自己）
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

        /// 卡片在这个画板或它的任何一层里层画板里
        func holds(_ board: Int64, _ card: Int64) -> Bool {
            ([board] + (inner[board] ?? [])).contains { members[$0]?.contains(card) == true }
        }

        /// 画板里有向量的卡，按和 vector 的相似度从高到低
        func nearest(_ board: Int64, to vector: [Float]) -> [(card: SearchCard, vector: [Float])] {
            (members[board] ?? []).compactMap { id in cards[id].flatMap { c in c.vector.map { (c, $0) } } }
                .sorted { dot($0.vector, vector) > dot($1.vector, vector) }
        }
    }

    // MARK: 判断

    /// 挑候选、问 Jev，给出每个候选画板的概率；没有候选时为空。nil 表示判断不了
    func score(_ id: Int64, in s: Snapshot) async -> [Scored]? {
        guard let card = s.cards[id], let vector = card.vector else { return nil }
        // 参与的画板：开着自动分拣，卡片不在它和它的里层画板里，至少有一张卡或者写了规则
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
        // 规则当作搜索里的一句话来算
        guard let v = try? await gateway.embed(rule, as: .query) else { return nil }
        ruleVectors[key] = v
        return v
    }

    /// 一个参与分拣的画板：里面卡片的向量、规则的向量
    struct Pool {
        var id: Int64
        var cards: [[Float]]
        var rule: [Float]?
    }

    /// 两份名单分开取再合起来去重：按卡片比（和画板里最像的 3 张的平均相似度，不到 3 张用全部）取前 5，按规则比取前 3。
    /// 不合成一个分数：「卡和卡」与「规则和卡」的相似度不在一把尺子上，只写了规则的画板会被系统性地挤掉。也不设最低分，相似度低的交给 Jev 否掉
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

    /// 现在的判断接口只给概率最高的答案和它的概率：答「否」时，属于的概率是 1 减去它
    static func probability(_ v: Verdict) -> Double { v.yes ? v.confidence : 1 - v.confidence }

    /// 每个画板各自和放进线比，一张卡可以放进好几个。嵌套的只放最里层：B 在 A 里（隔几层也算）、B 会放进时 A 不放
    static func pick(_ scored: [Scored], line: Double, inner: [Int64: Set<Int64>]) -> [Scored] {
        let passed = scored.filter { $0.probability >= line }
        let boards = Set(passed.map(\.board))
        return passed.filter { inner[$0.board, default: []].isDisjoint(with: boards) }
    }

    /// 每个候选画板一道题：画板名、规则、画板里和新卡最像的几张卡。
    /// 问「属于这个画板的主题吗」比问「应该放进去吗」更合 Jev 的路子：同样不放错，该放的放进了从 36% 升到 47%（SortCheck）
    static func question(_ board: Board, examples: [SearchCard]) -> Question {
        var text = "用户的画板「\(board.name)」收同一类主题的卡片。这张新卡片属于这个画板的主题吗？"
        if let rule = board.rule { text += "\n这个画板收：\(rule)" }
        if !examples.isEmpty { text += "\n画板里和它最像的几张卡：\n" + examples.map { "- " + $0.brief }.joined(separator: "\n") }
        return Question(text, .yesNo)
    }
}
