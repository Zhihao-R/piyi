import Foundation
import Library

/// A set of inspiration: a few cards and the connection the model states
public struct Inspiration: Sendable, Equatable {
    public var cards: [Int64]
    public var text: String
}

/// Inspiration: draw a few cards with similar meaning but different types for the model, which picks two to five that are truly connected and states the connection.
/// It isn't asked to string together every card drawn: forcing four or five unrelated things together leaves only one way to write it, "touch each one in turn, then close with a grand moral".
/// Several sets are prepared in the background for each scope, so switching sets is instant
public actor Inspirer {
    let searcher: Searcher
    let gateway: Gateway
    /// Prepared sets, kept apart by scope and topic
    private var ready: [Key: [Inspiration]] = [:]
    private var filling: [Key: Task<Void, Never>] = [:]
    /// Cards shown recently: avoided when picking
    private var recentCards: [Int64] = []
    /// Which kind of connection is up next
    private var turn = 0

    struct Key: Hashable { var scope: Scope; var topic: String }

    /// How many sets to prepare per scope. Pressing "Try Another Set" repeatedly uses up the prepared ones, after which each set must be written and checked on the spot, so prepare one extra
    static let stock = 3
    /// At least how many to draw for the model to pick from: when the current board doesn't have enough, fill from all cards
    static let least = 3
    /// At most how many to draw for the model to pick from
    static let offered = 8
    /// How many the model picks from them
    static let chosen = 2...5
    /// Number of cards wanted each round, taken in turn; pick fewer if that many can't be found
    static let sizes = [3, 2, 4, 3, 5]
    /// When no connection can be found among the drawn cards, or one is written but fails the check, try again with a new batch and another kind of connection, at most this many times.
    /// The check blocks more than half (about 60% measured); fewer than one in ten still can't produce a set after 5 tries
    static let attempts = 5
    /// Longest wait for writing a set on the spot (seconds): once reached, stop retrying with new batches and tell you none was found, rather than leaving you waiting
    static let patience = 25.0
    /// Separate time limits for one write and one check (seconds). Usually back in two or three seconds; stuck ones aren't waited for
    static let callTimeout = 12.0

    /// The one kind of connection to look at this time. The code rotates it, so consecutive sets aren't written the same way; not relying on telling the model to "say it differently"
    enum Angle: CaseIterable {
        case form, opposite, subject, borrow

        var ask: String {
            switch self {
            case .form: "画面或文字的形式上有同一种做法：构图、线条、形状、颜色、材质、排版、句式"
            case .opposite: "面对同一件事，做法正好相反"
            case .subject: "讲的或画的是同一样东西，只是出现在不同的年代、地方或媒介里"
            case .borrow: "一件里的具体做法，可以直接拿去用在另一件上"
            }
        }
    }

    public init(searcher: Searcher, gateway: Gateway) {
        self.searcher = searcher
        self.gateway = gateway
    }

    /// The library changed: prepared sets may point to deleted cards, so throw them away and prepare again
    public func invalidate() {
        ready = [:]
        for task in filling.values { task.cancel() }
        filling = [:]
    }

    /// Get a set: give a prepared one right away if there is one, otherwise make one now; then restock in the background. When topic isn't empty, pick only among cards related to the topic
    public func next(scope: Scope, topic: String = "") async throws -> Inspiration {
        let key = Key(scope: scope, topic: topic)
        defer { refill(key) }
        if var stock = ready[key], !stock.isEmpty {
            let first = stock.removeFirst()
            ready[key] = stock
            return first
        }
        return try await make(key)
    }

    /// Prepare several sets in the background
    public func prepare(scope: Scope) { refill(Key(scope: scope, topic: "")) }

    private func refill(_ key: Key) {
        guard filling[key] == nil else { return }
        let id = UUID()
        fillers[key] = id
        filling[key] = Task(priority: .utility) {
            while (ready[key]?.count ?? 0) < Self.stock, !Task.isCancelled {
                guard let made = try? await make(key), !Task.isCancelled else { break }
                ready[key, default: []].append(made)
            }
            // Invalidated meanwhile and a new restock started: the registration belongs to the new task, leave it alone
            if fillers[key] == id { filling[key] = nil }
        }
    }

    private var fillers: [Key: UUID] = [:]

    public enum Failure: LocalizedError {
        case tooFew, silent, nothing
        public var errorDescription: String? {
            switch self {
            case .tooFew: String(localized: "理解完的卡还太少，凑不出一组")
            case .silent: String(localized: "模型没有回应，再试一次")
            case .nothing: String(localized: "这次没找出有联系的几张，再试一次")
            }
        }
    }

    private func make(_ key: Key) async throws -> Inspiration {
        let all = await searcher.snapshot()
        var pool = all.filter { $0.vector != nil }
        // With a topic, look for related cards among all cards; scope only decides where to start: if the scope is short, others can be filled in from elsewhere
        if !key.topic.isEmpty {
            let related = Set(await searcher.related(QueryRules.parse(key.topic)))
            pool = pool.filter { related.contains($0.id) }
        }
        var home: Set<Int64> = if case .board(let b) = key.scope { Set(pool.filter { $0.boards.contains(b) }.map(\.id)) } else { Set(pool.map(\.id)) }
        // Empty board: start from all cards
        if home.isEmpty { home = Set(pool.map(\.id)) }
        let deadline = ContinuousClock.now + .seconds(Self.patience)
        for _ in 0..<Self.attempts where ContinuousClock.now < deadline {
            guard let offered = Self.pick(from: pool, home: home, avoiding: Set(recentCards)) else { throw Failure.tooFew }
            // Which kind of connection to look for this round and how many items are both rotated by the program: left to the model, the writing grows more and more alike and it picks two items every time.
            // Two cycles (4 and 5) are offset, so every kind of connection gets every count in turn
            let (angle, wanted) = (Angle.allCases[turn % Angle.allCases.count], Self.sizes[turn % Self.sizes.count])
            turn += 1
            guard let reply = try await explain(offered, angle: angle, wanted: wanted, topic: key.topic, until: deadline),
                  let picked = Self.chosen(reply.cards, from: offered) else { continue }
            // The more specific the writing, the more specific the fabrications ("both paintings have horses"): check it again against the picked cards, and don't show anything that doesn't match
            guard await holds(reply.text, for: picked.compactMap { id in offered.first { $0.id == id } }, until: deadline) else { continue }
            // Record the picked ones: the next set prepared in the background avoids them; unpicked ones can appear again
            recentCards = Array((picked + recentCards).prefix(24))
            return Inspiration(cards: picked, text: reply.text)
        }
        throw Failure.nothing
    }

    /// Turn the numbers the model picked into cards: must be two to five, no repeats, all among those drawn for it, otherwise the set doesn't count
    static func chosen(_ numbers: [Int], from offered: [SearchCard]) -> [Int64]? {
        let cards = numbers.compactMap { offered.indices.contains($0 - 1) ? offered[$0 - 1].id : nil }
        guard cards.count == numbers.count, Set(cards).count == cards.count, chosen.contains(cards.count) else { return nil }
        return cards
    }

    /// Pick a set: every pairwise similarity falls in the library's high range, mixing different types as much as possible.
    /// The connection should be real, so pick cards with similar meaning; the surprise comes from different types and sources (a painting and a passage about the same thing), not from distant meanings.
    /// It used to take the middle 25%–70% percentile, where most cards are actually unrelated and the model could only make things up (11 of 19 failed the check in testing).
    /// Now it takes the 80%–97% percentile: the top 3% are mostly the same batch of things (same painter, several images from one article), with nothing new
    /// At most offered cards are drawn for the model to pick from. Starts from cards in the current scope, filling the rest from all cards when the scope is short
    static func pick(from pool: [SearchCard], home: Set<Int64>, avoiding recent: Set<Int64>) -> [SearchCard]? {
        guard pool.count >= least else { return nil }
        let sims = (0..<min(3000, pool.count * pool.count)).compactMap { _ -> Float? in
            let a = pool.randomElement()!, b = pool.randomElement()!
            return a.id == b.id ? nil : dot(a.vector!, b.vector!)
        }.sorted()
        guard sims.count > 10 else { return nil }
        let band = sims[Int(Double(sims.count) * 0.8)]...sims[Int(Double(sims.count) * 0.97)]
        let fits = { (group: [SearchCard], c: SearchCard) in group.allSatisfy { $0.id != c.id && band.contains(dot($0.vector!, c.vector!)) } }

        let size = offered
        let anchors = pool.filter { home.contains($0.id) && !recent.contains($0.id) }.shuffled()
        for anchor in (anchors.isEmpty ? pool.filter { home.contains($0.id) }.shuffled() : anchors).prefix(12) {
            var group = [anchor]
            // Look in the scope first, then fill from elsewhere; other things equal, prefer types different from those already chosen and cards not shown recently
            let candidates = pool.shuffled().sorted { rank($0, home, recent) < rank($1, home, recent) }
            while group.count < size, let next = candidates.first(where: { c in fits(group, c) && !group.contains { $0.kind == c.kind } })
                    ?? candidates.first(where: { fits(group, $0) }) {
                group.append(next)
            }
            if group.count >= least { return group }
        }
        return nil
    }

    private static func rank(_ c: SearchCard, _ home: Set<Int64>, _ recent: Set<Int64>) -> Int {
        (home.contains(c.id) ? 0 : 2) + (recent.contains(c.id) ? 1 : 0)
    }

    struct Reply: Decodable { var cards: [Int]; var text: String }

    /// Have the model pick from the drawn cards and write. Throws when there's no response; if it responds but picks nothing (cards empty), the caller retries with a new batch
    private func explain(_ cards: [SearchCard], angle: Angle, wanted: Int, topic: String, until deadline: ContinuousClock.Instant) async throws -> Reply? {
        var pictures: [Data] = []
        var lines: [String] = []
        for (i, card) in cards.enumerated() {
            var line = "\(i + 1). \(card.brief)"
            if let cover = card.cover, let jpeg = Prompt.glance(cover, files: searcher.store.files) {
                pictures.append(jpeg)
                line += "（附图 \(pictures.count)）"
            }
            lines.append(line)
        }
        let prompt = Self.prompt(lines, angle: angle, topic: topic, wanted: wanted)
        let (gateway, attached) = (gateway, pictures)
        guard let reply = await within(Self.time(left: deadline), { try await gateway.generate(prompt, images: attached, as: Reply.self) }) else {
            throw Failure.silent
        }
        return reply.text.isEmpty ? nil : reply
    }

    /// Check: using only the picked cards (description lines and images) and the written text, ask two things: what it says is visible in the cards, and it actually states a connection.
    /// If either fails, or can't be judged (timeout, error), it doesn't count: better to switch sets than show something unchecked
    private func holds(_ text: String, for cards: [SearchCard], until deadline: ContinuousClock.Instant) async -> Bool {
        var pictures: [Data] = []
        var facts: Facts = []
        for card in cards {
            var line = card.brief
            if let cover = card.cover, let jpeg = Prompt.glance(cover, files: searcher.store.files) {
                pictures.append(jpeg)
                line += "（附图 \(pictures.count)）"
            }
            facts.append(("东西 \(facts.count + 1)", line))
        }
        facts.append(("有人这样说它们", text))
        let (gateway, checked, attached) = (gateway, facts, pictures)
        let verdicts = await within(Self.time(left: deadline)) { try await gateway.judge(checked, Self.checks, images: attached) }
        return verdicts?.allSatisfy(\.yes) == true
    }

    /// Longest wait for this call: no more than the per-call limit, and no more than this set's remaining time. That makes patience a real upper bound
    static func time(left deadline: ContinuousClock.Instant) -> Double {
        let left = deadline - .now
        return max(0, min(callTimeout, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18))
    }

    static let checks = [
        Question("这段话里说到的每一处，在这几件东西的附图或说明里都看得到、对得上吗？有一处看不到、张冠李戴，或者说的联系其实只有一件有，就选否。", .yesNo),
        Question("这段话有没有指出一个这几件东西共有的、或者正好相反的具体的点？只是把它们各描述一句、没有共同点也没有对立点的，或者共同点宽泛到随便两样东西都有的（都有人物、都分了层、都用了线条），选否。", .yesNo),
    ]

    static func prompt(_ lines: [String], angle: Angle, topic: String, wanted: Int = 2) -> String {
        """
        下面是从用户的收藏里随手抽出的 \(lines.count) 件东西\(topic.isEmpty ? "" : "，用户想要的主题是「\(topic)」，联系要和主题有关")。它们大多彼此没有关系，不要把它们全串起来。
        这次只找这一种联系：\(angle.ask)。
        从里面挑出 \(wanted) 件都有这个联系的\(wanted > chosen.lowerBound ? "；实在凑不出 \(wanted) 件，才少挑，最少 \(chosen.lowerBound) 件" : "")。每一件都得真有，不为凑数加进来。

        写法：
        \(Writing.Part.inspiration.style)
        另外：
        - 直接说出联系是什么，具体到别人把这几件摆在一起就能看见、能核对。不写「都在说」「都是关于」「少即是多」这类总结。
        - 联系要是字面上的：要靠比喻、成语、引申才说得通的不算。一眼就看得出的也不算：同一个作者、同一个话题、同一样东西的两个版本。
        - 类型不同的几件（一张图和一段话、一个视频和一幅画）有联系时优先挑它们。
        - 只说附图和说明里看得见、读得到的；不提时长、格式、字数、网址这类信息，也不补你自己知道的背景。
        - 用东西的名字称呼它们，不写「第 3 件」「第一张图」「三张图里」这样的叫法。用\(Writing.language)写。
        - 这几件里找不出这种联系，就让 cards 为空，不要凑。

        \(lines.joined(separator: "\n"))

        只输出 JSON：{"cards":[挑中的编号],"text":"你写的内容"}
        """
    }
}
