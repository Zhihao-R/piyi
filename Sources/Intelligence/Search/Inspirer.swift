import Foundation
import Library

/// 一组灵感：几张卡和模型说出的联系
public struct Inspiration: Sendable, Equatable {
    public var cards: [Int64]
    public var text: String
}

/// 灵感：抽几张意思相近、类型不同的卡给模型，由它从里面挑出两到五张确实有联系的，说出联系。
/// 不让它把抽到的每一张都串起来：硬串四五张不相干的东西，只剩「逐张点一遍、再用一句大道理收尾」这一种写法。
/// 每个范围后台预先备好几组，换一组时立刻出现
public actor Inspirer {
    let searcher: Searcher
    let gateway: Gateway
    /// 备好的几组，按范围和主题分开
    private var ready: [Key: [Inspiration]] = [:]
    private var filling: [Key: Task<Void, Never>] = [:]
    /// 最近出现过的卡：挑卡时避开
    private var recentCards: [Int64] = []
    /// 轮到第几种联系
    private var turn = 0
    /// 问了几次、几次没挑出来、几次写了但核对不上：检查集据此报丢弃率
    private(set) var tally = (asked: 0, empty: 0, refuted: 0)

    struct Key: Hashable { var scope: Scope; var topic: String }

    /// 每个范围备几组。连着按「换一组」时备好的先用完，之后每组都要现写、现核对，所以多备一组
    static let stock = 3
    /// 抽给模型挑的至少几张：当前画板不够时从全部卡片里配
    static let least = 3
    /// 抽给模型挑的最多几张
    static let offered = 8
    /// 模型从里面挑中几张
    static let chosen = 2...5
    /// 每一轮想要的张数，轮着来；凑不出就少挑
    static let sizes = [3, 2, 4, 3, 5]
    /// 抽到的几张里找不出联系、或者写了但核对不上时，换一批、换一种联系再试，最多几次。
    /// 核对会拦掉一多半（InspireCheck 实测六成左右），试 5 次还凑不出一组的不到一成
    static let attempts = 5
    /// 现写一组最多等多久（秒）：到了就不再换一批重试，告诉你没找出来，不让人干等
    static let patience = 25.0
    /// 写一次、核对一次各自的限时（秒）。平时两三秒就回来，卡住的不等它
    static let callTimeout = 12.0

    /// 这次只看哪一种联系。由代码轮着换，连着几组不会是一个写法；不靠嘱咐模型「换一种说法」
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

    /// 资料库变了：备好的组可能指向已删的卡，扔掉重备
    public func invalidate() {
        ready = [:]
        for task in filling.values { task.cancel() }
        filling = [:]
    }

    /// 来一组：有备好的立刻给，没有就现做；然后在后台补货。topic 不为空时只在和主题相关的卡里挑
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

    /// 后台预先备好几组
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
            // 期间被作废、又起了新的补货：登记是新任务的，不动它
            if fillers[key] == id { filling[key] = nil }
        }
    }

    private var fillers: [Key: UUID] = [:]

    public enum Failure: LocalizedError {
        case tooFew, silent, nothing
        public var errorDescription: String? {
            switch self {
            case .tooFew: "理解完的卡还太少，凑不出一组"
            case .silent: "模型没有回应，再试一次"
            case .nothing: "这次没找出有联系的几张，再试一次"
            }
        }
    }

    private func make(_ key: Key) async throws -> Inspiration {
        let all = await searcher.snapshot()
        var pool = all.filter { $0.vector != nil }
        // 带主题时在全部卡片里找相关的，范围只决定从哪里起头：范围里凑不够也能从别处配
        if !key.topic.isEmpty {
            let related = Set(await searcher.related(QueryRules.parse(key.topic)))
            pool = pool.filter { related.contains($0.id) }
        }
        var home: Set<Int64> = if case .board(let b) = key.scope { Set(pool.filter { $0.boards.contains(b) }.map(\.id)) } else { Set(pool.map(\.id)) }
        // 空画板：以全部卡片为起点
        if home.isEmpty { home = Set(pool.map(\.id)) }
        let deadline = ContinuousClock.now + .seconds(Self.patience)
        for _ in 0..<Self.attempts where ContinuousClock.now < deadline {
            guard let offered = Self.pick(from: pool, home: home, avoiding: Set(recentCards)) else { throw Failure.tooFew }
            // 这一轮找哪种联系、想要几件都由程序轮着定：让模型自己定的话，写法越写越像，张数每次都是两件。
            // 两个周期（4 和 5）错开，每种联系都轮得到各种张数
            let (angle, wanted) = (Angle.allCases[turn % Angle.allCases.count], Self.sizes[turn % Self.sizes.count])
            turn += 1
            tally.asked += 1
            guard let reply = try await explain(offered, angle: angle, wanted: wanted, topic: key.topic, until: deadline),
                  let picked = Self.chosen(reply.cards, from: offered) else { tally.empty += 1; continue }
            // 写得具体了，编出来的也具体（「两幅画里都有马」）：对着挑中的这几张再核对一遍，对不上的不给人看
            guard await holds(reply.text, for: picked.compactMap { id in offered.first { $0.id == id } }, until: deadline) else { tally.refuted += 1; continue }
            // 挑中的记下：后台备的下一组避开它们；没挑中的还能再出现
            recentCards = Array((picked + recentCards).prefix(24))
            return Inspiration(cards: picked, text: reply.text)
        }
        throw Failure.nothing
    }

    /// 模型挑中的编号换成卡：要两到五张、互不重复、都在抽给它的那几张里，不然这一组不算
    static func chosen(_ numbers: [Int], from offered: [SearchCard]) -> [Int64]? {
        let cards = numbers.compactMap { offered.indices.contains($0 - 1) ? offered[$0 - 1].id : nil }
        guard cards.count == numbers.count, Set(cards).count == cards.count, chosen.contains(cards.count) else { return nil }
        return cards
    }

    /// 挑一组：两两之间的相似度都落在全库的高段，尽量混合不同类型。
    /// 联系要是真的，所以挑意思相近的；意外感来自类型和出处不同（一张画和一段话讲的是同一件事），不来自意思离得远。
    /// 原先取 25%～70% 分位的中段，那里的卡多数其实没有关系，模型只能硬编（InspireCheck：19 次里 11 次核对不上）。
    /// 现在取 80%～97% 分位：最顶上的 3% 多是同一批东西（同一个画家、同一篇文章的几张图），没有新意
    /// 抽给模型挑的张数最多 offered 张。以当前范围里的卡为起点，范围里不够时其余从全部卡片里配
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
            // 先在范围里找，再从别处配；同等条件下优先和已选的类型不同、最近没出现过的
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

    /// 让模型从抽到的几张里挑、写。没回应时抛出去；回了但没挑出来（cards 为空）由调用方换一批再试
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

    /// 核对：只拿挑中的这几张（说明行和图）和写好的话去问两件事，说的在卡里看得到，而且真说出了一个联系。
    /// 有一件不成立，或者判断不了（超时、出错），都不算：宁可换一组，不给人看没核对过的
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

    /// 这一次调用最多等多久：不超过单次的限时，也不超过这一组剩下的时间。patience 因此是真的上限
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

        怎么写：
        - 直接说出联系是什么，具体到别人把这几件摆在一起就能看见、能核对。一两句，说完就停，不加建议和感想。
        - 联系要是字面上的：要靠比喻、成语、引申才说得通的不算。一眼就看得出的也不算：同一个作者、同一个话题、同一样东西的两个版本。
        - 类型不同的几件（一张图和一段话、一个视频和一幅画）有联系时优先挑它们。
        - 只说附图和说明里看得见、读得到的；不提时长、格式、字数、网址这类信息，也不补你自己知道的背景。
        - 不讲道理，不写「都在说」「都是关于」「少即是多」这类总结；不用比喻，不用破折号。
        - 用东西的名字称呼它们，不写「第 3 件」「第一张图」「三张图里」这样的叫法。不超过 100 字。
        - 这几件里找不出这种联系，就让 cards 为空，不要凑。

        \(lines.joined(separator: "\n"))

        只输出 JSON：{"cards":[挑中的编号],"text":"你写的内容"}
        """
    }
}
