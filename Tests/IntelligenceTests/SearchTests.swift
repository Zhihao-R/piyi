import Testing
import Foundation
@testable import Intelligence
@testable import Library

/// 关键词规则：意图提示词、时间、类型、颜色
@Suite struct Rules {
    @Test func intents() {
        #expect(QueryRules.parse("帮我抽一张塔罗牌").intent == .draw)
        #expect(QueryRules.parse("给我点灵感").intent == .inspire)
        #expect(QueryRules.parse("我收过的配色文章都在讲什么").intent == .ask)
        #expect(QueryRules.parse("这两种做法有什么区别？").intent == .ask)
        #expect(QueryRules.parse("古代文本").intent == .find)
    }

    @Test func conditionsMergeWithButtons() {
        var filters = Filters()
        filters.kinds = [.image]
        filters.color = .red
        let q = QueryRules.parse("最近的视频", filters: filters)
        #expect(q.days == 14)
        #expect(q.kinds == [.image, .video])
        #expect(q.colors == [.red])
        #expect(q.semantic.isEmpty)
    }

    /// 判断模型回来以后：它说了算有没有条件，规则只去掉它认的那几个词
    @Test func judgedConditionsDecideWhichWordsGo() {
        let none = QueryRules.Judged(intent: .inspire, timed: false, kind: nil, color: nil, visual: false)
        let food = QueryRules.parse("今天吃什么", judged: none)
        #expect(food.intent == .inspire && food.days == nil && food.semantic.contains("今天"))

        let clear = QueryRules.parse("明白人说的话", judged: QueryRules.Judged(intent: .find, timed: false, kind: nil, color: nil, visual: false))
        #expect(clear.colors.isEmpty)
        // 只有颜色字、模型说不算颜色条件：留着当要找的内容，不至于什么条件都没有
        #expect(!QueryRules.parse("白色", judged: QueryRules.Judged(intent: .find, timed: false, kind: nil, color: nil, visual: false)).isEmpty)

        let articles = QueryRules.parse("上周收的讲配色的文章", judged: QueryRules.Judged(intent: .find, timed: true, kind: .web, color: nil, visual: false))
        #expect(articles.days == 14)
        #expect(articles.kinds == [.web, .document, .text])
        #expect(!articles.semantic.contains("文章") && !articles.semantic.contains("上周") && articles.semantic.contains("配色"))

        let poster = QueryRules.parse("最近收的红色海报", judged: QueryRules.Judged(intent: .find, timed: true, kind: nil, color: .red, visual: false))
        #expect(poster.days == 14 && poster.colors == [.red] && poster.semantic.contains("海报"))

        let video = QueryRules.parse("视频网站怎么赚钱", judged: QueryRules.Judged(intent: .find, timed: false, kind: nil, color: nil, visual: false))
        #expect(video.kinds.isEmpty && video.semantic.contains("视频"))
    }
}

/// 会漏的几种情形
@Suite struct Recall {
    static func judged(_ intent: Intent, timed: Bool = false) -> QueryRules.Judged {
        QueryRules.Judged(intent: intent, timed: timed, kind: nil, color: nil, visual: false)
    }

    /// 5.1 模型说限定了时间、规则认不出是几天：不加时间条件，时间词留着按意思找
    @Test func unknownTimeWordAddsNoCondition() {
        for text in ["去年收的海报", "三月的展览"] {
            let q = QueryRules.parse(text, judged: Self.judged(.find, timed: true))
            #expect(q.days == nil, "\(text)")
        }
        #expect(QueryRules.parse("去年收的海报", judged: Self.judged(.find, timed: true)).semantic.contains("去年"))
        // 认得出的照旧；筛选按钮选的时间也照旧
        #expect(QueryRules.parse("上周的海报", judged: Self.judged(.find, timed: true)).days == 14)
        var filters = Filters()
        filters.days = 7
        #expect(QueryRules.parse("去年收的海报", filters: filters, judged: Self.judged(.find, timed: true)).days == 7)
    }

    /// 5.2 模型判为找卡片、提问：用原句，指令词是要找的东西
    @Test func judgedFindKeepsTheWholeSentence() {
        let tarot = QueryRules.parse("塔罗牌插画", judged: Self.judged(.find))
        #expect(tarot.intent == .find && tarot.semantic == "塔罗牌插画")
        let board = QueryRules.parse("灵感板参考", judged: Self.judged(.find))
        #expect(board.semantic == "灵感板参考" && board.tokens.joined().contains("灵感"))
        #expect(QueryRules.parse("塔罗牌是怎么来的", judged: Self.judged(.ask)).semantic.contains("塔罗"))
        // 真是要灵感、抽一张时照旧去掉指令词，剩下的是主题
        let food = QueryRules.parse("今天吃什么，给我点灵感", judged: Self.judged(.inspire))
        #expect(food.semantic.contains("吃什么") && !food.semantic.contains("灵感"))
    }

    /// 5.2 没有模型时：整句就是指令才当指令，否则当找卡片，词一个不少
    @Test func withoutModelOnlyWholeSentenceCommands() {
        for text in ["抽一张", "抽一张！", "帮我抽一张塔罗牌", "随机一张"] { #expect(QueryRules.parse(text).intent == .draw, "\(text)") }
        for text in ["给我点灵感", "来点灵感"] { #expect(QueryRules.parse(text).intent == .inspire, "\(text)") }
        for text in ["塔罗牌插画", "塔罗", "灵感", "灵感板参考", "今天吃什么，给我点灵感", "抽一张的设计"] {
            let q = QueryRules.parse(text)
            #expect(q.intent == .find, "\(text)")
            #expect(!q.tokens.isEmpty, "\(text)")
        }
        #expect(QueryRules.parse("塔罗牌插画").semantic == "塔罗牌插画")
        #expect(QueryRules.parse("灵感板参考").semantic == "灵感板参考")
    }

    static func row(_ card: Card) -> SearchCard {
        Searcher.searchCard(SearchRow(card: card, vector: nil, model: nil, boards: []), model: nil)
    }

    /// 5.3 字面匹配查全部正文和字幕，不只开头
    @Test func literalMatchReadsWholeBodyAndTranscript() {
        var article = Card(kind: .web)
        article.id = 1
        article.body = String(repeating: "前面的内容。", count: 400) + "结尾提到了榫卯结构。"
        var video = Card(kind: .video)
        video.id = 2
        video.body = String(repeating: "视频简介。", count: 200)
        video.transcript = String(repeating: "开场白。", count: 300) + "这里讲到了景深合成。"
        let cards = [Self.row(article), Self.row(video)]

        var q = Query(text: "榫卯")
        q.lookFor("榫卯")
        #expect(Ranking.literal(cards, q) == [1])
        q.lookFor("景深合成")
        #expect(Ranking.literal(cards, q) == [2])
        // 给模型看的一行仍然只带开头
        #expect(!cards[0].brief.contains("榫卯"))
    }

    /// 5.4 还没算出向量的卡，查询词字面全中就保底入选；只中一部分的不保，有向量的照旧看分数线
    @Test func literalFullMatchAlwaysShown() {
        func card(_ id: Int64, _ text: String, _ vector: [Float]?) -> SearchCard {
            SearchCard(id: id, kind: .text, collectedAt: .now, text: text, colors: nil, vector: vector)
        }
        let query: [Float] = [1, 0]
        var cards = [card(1, "包豪斯 海报", nil), card(2, "包豪斯 海报", [-1, 0]), card(3, "只提到包豪斯", nil), card(4, "别的", [1, 0])]
        cards += (5..<25).map { card($0, "别的", [0, 1]) }
        var q = Query(text: "包豪斯海报")
        q.semantic = "包豪斯海报"
        q.tokens = ["包豪斯", "海报"]
        let scored = Ranking.scored(cards, q, semantic: query)
        let shown = Ranking.shown(scored, semantic: true)
        #expect(scored.first?.id == 4)
        #expect(shown.contains(1))
        #expect(!shown.contains(2) && !shown.contains(3))
        // 保底不改名次：分数高的仍然排在前面
        #expect(shown.first == 4)
    }

    /// 5.4 生成失败的卡照样算向量：记下失败，但按意思找得到
    @Test func failedGenerationStillGetsVector() async throws {
        let store = try temporaryStore()
        let id = try await collectPage(store, url: "https://example.com/offline")
        await Understander(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [BrokenCloud()])) {}.run()
        for _ in 0..<50 where try await store.card(id)?.understandError == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await store.card(id)?.understandError != nil)
        #expect(try await store.vectorBases()[id] != nil)
    }
}

/// 生成总是失败的云端（断网时的样子）
struct BrokenCloud: Generation {
    let name = "断网的云端", isReady = true
    func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String { throw URLError(.notConnectedToInternet) }
}

/// 按卡片的一行简介预设相关程度的假判断服务方；没预设的答「无关」
struct GradingJudge: Judgment {
    let name = "假精排", isReady = true, seesImages = false, sureEnough = 0.5
    var grades: [String: Int]

    func judge(_ facts: Facts, _ questions: [Question], images: [Data]) async throws -> [Verdict] {
        questions.map { _ in Verdict(choice: 0, confidence: 0.9) }
    }

    func judge(each items: [String], _ question: Question, about facts: Facts, images: [Data]) async throws -> [Verdict] {
        items.map { Verdict(choice: grades[$0] ?? 0, confidence: 0.9) }
    }
}

/// 5.5 回车后结果分批到：本机的先给，云端精排回来只在换了一批卡时才再给
@Suite struct Batches {
    /// 四张卡：1、2 字面和向量都对得上「海报」，本机粗找只展示它们；3、4 是精排可能捞回来的
    static func searcher(grades: [String: Int]) async throws -> Searcher {
        let searcher = Searcher(store: try temporaryStore(), gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [], judges: [GradingJudge(grades: grades)]))
        await searcher.replaceCards((1...4).map {
            SearchCard(id: $0, kind: .text, collectedAt: .now, text: $0 <= 2 ? "海报" : "别的", colors: nil, vector: $0 <= 2 ? [0, 1, 0] : [0, 0, 1], brief: "卡\($0)")
        })
        return searcher
    }

    static var query: Query {
        var q = Query(text: "海报")
        q.lookFor("海报")
        return q
    }

    static func batches(_ stream: AsyncStream<[Int64]>) async -> [[Int64]] {
        var all: [[Int64]] = []
        for await cards in stream { all.append(cards) }
        return all
    }

    /// 云端只是换了顺序：只给本机那一批，卡片不动第二次
    @Test func sameCardsReorderedByCloudAreNotGivenAgain() async throws {
        let searcher = try await Self.searcher(grades: ["卡1": 2, "卡2": 3])
        #expect(await searcher.find(Self.query, online: true) == [2, 1])
        let batches = await Self.batches(searcher.finding(Self.query, online: true))
        #expect(batches.count == 1)
        #expect(Set(batches[0]) == [1, 2])
    }

    /// 云端捞回一张、去掉一张：再给一次云端的结果
    @Test func differentCardsFromCloudReplaceLocalOnes() async throws {
        let searcher = try await Self.searcher(grades: ["卡1": 3, "卡3": 2])
        let batches = await Self.batches(searcher.finding(Self.query, online: true))
        #expect(batches.count == 2)
        #expect(Set(batches[0]) == [1, 2])
        #expect(batches[1] == [1, 3])
    }

    /// 离线：只有本机那一批
    @Test func offlineGivesLocalOnly() async throws {
        let searcher = try await Self.searcher(grades: ["卡3": 3])
        #expect(await Self.batches(searcher.finding(Self.query, online: false)).map(Set.init) == [[1, 2]])
    }

    /// 眼前已经聚拢着一批（回车时按规则先找的）：等云端的，同一批就什么都不给，不同才给一次
    @Test func alreadyGatheredWaitsForCloud() async throws {
        let same = try await Self.searcher(grades: ["卡1": 2, "卡2": 3])
        #expect(await Self.batches(same.finding(Self.query, online: true, over: [1, 2])).isEmpty)
        let different = try await Self.searcher(grades: ["卡3": 3])
        #expect(await Self.batches(different.finding(Self.query, online: true, over: [1, 2])) == [[3]])
        // 云端判下来一张都不相关：给一个空批，界面据此散开
        let none = try await Self.searcher(grades: [:])
        #expect(await Self.batches(none.finding(Self.query, online: true, over: [1, 2])) == [[]])
    }
}

/// 离线时搜索不等网络
@Suite struct SearchOffline {
    let store: Store
    let cloud = FakeCloud()
    let gateway: Gateway

    init() throws {
        store = try temporaryStore()
        gateway = Gateway(embedder: FakeLocalEmbedder(), generators: [cloud])
    }

    /// 离线时不等网络：不调模型，只用规则和本机向量
    @Test func offlineNeverCallsTheModel() async throws {
        for i in 0..<3 { _ = try await collectPage(store, url: "https://example.com/\(i)", body: "设计 正文 \(i)") }
        await Understander(store: store, gateway: gateway) {}.run()
        cloud.calls.withLock { $0 = [] }
        let searcher = Searcher(store: store, gateway: gateway)
        let q = await searcher.interpret("视频网站怎么赚钱", filters: Filters(), online: false)
        _ = await searcher.find(q, online: false)
        #expect(cloud.calls.withLock { $0 }.isEmpty)
    }
}

/// 真实云端理解几句典型的话：OPENROUTER_API_KEY=… swift test --filter SearchRealCloud
@Suite struct SearchRealCloud {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
    func interpretsSentences() async throws {
        let store = try temporaryStore()
        let cloud = Cloud(key: { _ in ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] })
        let searcher = Searcher(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [cloud], judges: [Jev(via: cloud)]))
        // 两可的句子接受两种理解：「视频网站怎么赚钱」「明白人说的话」当成找卡片、提问都行（提问时依据的卡也会聚拢过来）
        let cases: [(String, Set<Intent>)] = [
            ("视频网站怎么赚钱", [.find, .ask]), ("今天吃什么，给我点灵感", [.inspire]), ("帮我抽一张塔罗牌", [.draw]),
            ("我收过的讲设计的文章都在说什么？", [.ask]), ("长得像狗狗的男人", [.find]), ("明白人说的话", [.find, .ask]), ("最近收的红色海报", [.find]),
        ]
        for (text, intent) in cases {
            let start = Date()
            let q = await searcher.interpret(text, filters: Filters(), online: true)
            print(String(format: "「%@」→ %@ 语义「%@」 天 %@ 类型 %@ 颜色 %@ 看图 %@（%.1f 秒）", text, q.intent.rawValue, q.semantic,
                         q.days.map(String.init) ?? "-", q.kinds.map(\.rawValue).sorted().description, q.colors.map(\.rawValue).description,
                         q.visual.description, Date().timeIntervalSince(start)))
            #expect(intent.contains(q.intent), "\(text)")
        }
        let video = await searcher.interpret("视频网站怎么赚钱", filters: Filters(), online: true)
        #expect(video.kinds.isEmpty)
        #expect(await searcher.interpret("最近收的红色海报", filters: Filters(), online: true).days == 14)
        let white = await searcher.interpret("明白人说的话", filters: Filters(), online: true)
        #expect(white.colors.isEmpty)
    }
}
