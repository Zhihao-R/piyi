import Testing
import Foundation
@testable import Intelligence
@testable import Library

/// Keyword rules: intent cue words, time, type, color
@Suite struct Rules {
    @Test func intents() {
        #expect(QueryRules.parse("帮我抽一张塔罗牌").intent == .draw)
        #expect(QueryRules.parse("给我点灵感").intent == .inspire)
        #expect(QueryRules.parse("我收过的配色文章都在讲什么").intent == .ask)
        #expect(QueryRules.parse("这两种做法有什么区别？").intent == .ask)
        #expect(QueryRules.parse("古代文本").intent == .find)
        // Phrasings from the English interface
        #expect(QueryRules.parse("Draw a card").intent == .draw)
        #expect(QueryRules.parse("Inspire me").intent == .inspire)
        #expect(QueryRules.parse("What is wabi-sabi").intent == .ask)
        #expect(QueryRules.parse("ancient texts").intent == .find)
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

    /// Once the judgment model answers: it decides whether there are conditions, and the rules only remove the words it recognized
    @Test func judgedConditionsDecideWhichWordsGo() {
        let none = QueryRules.Judged(intent: .inspire, timed: false, kind: nil, color: nil, visual: false)
        let food = QueryRules.parse("今天吃什么", judged: none)
        #expect(food.intent == .inspire && food.days == nil && food.semantic.contains("今天"))

        let clear = QueryRules.parse("明白人说的话", judged: QueryRules.Judged(intent: .find, timed: false, kind: nil, color: nil, visual: false))
        #expect(clear.colors.isEmpty)
        // Only a color word, and the model says it's not a color condition: keep it as the content to find, so we don't end up with no conditions at all
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

/// Cases that would slip through
@Suite struct Recall {
    static func judged(_ intent: Intent, timed: Bool = false) -> QueryRules.Judged {
        QueryRules.Judged(intent: intent, timed: timed, kind: nil, color: nil, visual: false)
    }

    /// 5.1 The model says there's a time limit but the rules can't tell how many days: no time condition, the time words stay and are searched by meaning
    @Test func unknownTimeWordAddsNoCondition() {
        for text in ["去年收的海报", "三月的展览"] {
            let q = QueryRules.parse(text, judged: Self.judged(.find, timed: true))
            #expect(q.days == nil, "\(text)")
        }
        #expect(QueryRules.parse("去年收的海报", judged: Self.judged(.find, timed: true)).semantic.contains("去年"))
        // What can be recognized works as before; time chosen with the filter button also works as before
        #expect(QueryRules.parse("上周的海报", judged: Self.judged(.find, timed: true)).days == 14)
        var filters = Filters()
        filters.days = 7
        #expect(QueryRules.parse("去年收的海报", filters: filters, judged: Self.judged(.find, timed: true)).days == 7)
    }

    /// 5.2 The model judges it as finding cards or asking a question: use the original sentence, the command words are what to find
    @Test func judgedFindKeepsTheWholeSentence() {
        let tarot = QueryRules.parse("塔罗牌插画", judged: Self.judged(.find))
        #expect(tarot.intent == .find && tarot.semantic == "塔罗牌插画")
        let board = QueryRules.parse("灵感板参考", judged: Self.judged(.find))
        #expect(board.semantic == "灵感板参考" && board.tokens.joined().contains("灵感"))
        #expect(QueryRules.parse("塔罗牌是怎么来的", judged: Self.judged(.ask)).semantic.contains("塔罗"))
        // For a real inspiration or draw-a-card request, the command words are still removed as before, and what remains is the topic
        let food = QueryRules.parse("今天吃什么，给我点灵感", judged: Self.judged(.inspire))
        #expect(food.semantic.contains("吃什么") && !food.semantic.contains("灵感"))
    }

    /// 5.2 Without a model: only treated as a command when the whole sentence is the command, otherwise as finding cards, with every word kept
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

    /// 5.3 Literal matching searches the whole body text and subtitles, not just the beginning
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
        // The line shown to the model still has only the beginning
        #expect(!cards[0].brief.contains("榫卯"))
    }

    /// 5.4 Cards without a vector yet are guaranteed a place if the query words all match literally; a partial match isn't, and cards with vectors still go by the score cutoff
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
        // The guarantee doesn't change ranking: higher scores still come first
        #expect(shown.first == 4)
    }

    /// 5.4 Cards whose generation failed still get vectors: the failure is recorded, but they can be found by meaning
    @Test func failedGenerationStillGetsVector() async throws {
        let store = try temporaryStore()
        let id = try await collectPage(store, url: "https://example.com/offline")
        await Understander(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [BrokenCloud()])) {}.run()
        for _ in 0..<50 where try await store.card(id)?.understandError == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await store.card(id)?.understandError != nil)
        #expect(try await store.vectorBases()[id] != nil)
    }
}

/// A cloud whose generation always fails (as when offline)
struct BrokenCloud: Generation {
    let name = "断网的云端", isReady = true
    func generate(_ prompt: String, images: [Data], careful: Bool) async throws -> String { throw URLError(.notConnectedToInternet) }
}

/// A fake judgment provider with relevance preset by each card's one-line brief; anything not preset is answered "irrelevant"
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

/// 5.5 After pressing Return, results arrive in batches: on-device ones first, and when cloud reranking comes back, only given again if the set of cards changed
@Suite struct Batches {
    /// Four cards: 1 and 2 match "海报" both literally and by vector, so the on-device rough search shows only them; 3 and 4 are ones reranking might bring back
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

    /// The cloud only changed the order: only the on-device batch is given, cards don't move a second time
    @Test func sameCardsReorderedByCloudAreNotGivenAgain() async throws {
        let searcher = try await Self.searcher(grades: ["卡1": 2, "卡2": 3])
        #expect(await searcher.find(Self.query, online: true) == [2, 1])
        let batches = await Self.batches(searcher.finding(Self.query, online: true))
        #expect(batches.count == 1)
        #expect(Set(batches[0]) == [1, 2])
    }

    /// The cloud brought one back and removed one: the cloud's result is given once more
    @Test func differentCardsFromCloudReplaceLocalOnes() async throws {
        let searcher = try await Self.searcher(grades: ["卡1": 3, "卡3": 2])
        let batches = await Self.batches(searcher.finding(Self.query, online: true))
        #expect(batches.count == 2)
        #expect(Set(batches[0]) == [1, 2])
        #expect(batches[1] == [1, 3])
    }

    /// Offline: only the on-device batch
    @Test func offlineGivesLocalOnly() async throws {
        let searcher = try await Self.searcher(grades: ["卡3": 3])
        #expect(await Self.batches(searcher.finding(Self.query, online: false)).map(Set.init) == [[1, 2]])
    }

    /// A batch is already gathered on screen (found by rules first on Return): wait for the cloud, give nothing if it's the same batch, give once if it differs
    @Test func alreadyGatheredWaitsForCloud() async throws {
        let same = try await Self.searcher(grades: ["卡1": 2, "卡2": 3])
        #expect(await Self.batches(same.finding(Self.query, online: true, over: [1, 2])).isEmpty)
        let different = try await Self.searcher(grades: ["卡3": 3])
        #expect(await Self.batches(different.finding(Self.query, online: true, over: [1, 2])) == [[3]])
        // The cloud judged none of them relevant: give an empty batch, and the interface scatters accordingly
        let none = try await Self.searcher(grades: [:])
        #expect(await Self.batches(none.finding(Self.query, online: true, over: [1, 2])) == [[]])
    }
}

/// Offline search doesn't wait for the network
@Suite struct SearchOffline {
    let store: Store
    let cloud = FakeCloud()
    let gateway: Gateway

    init() throws {
        store = try temporaryStore()
        gateway = Gateway(embedder: FakeLocalEmbedder(), generators: [cloud])
    }

    /// Offline it doesn't wait for the network: no model calls, only rules and on-device vectors
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

/// How the real cloud understands a few typical sentences: OPENROUTER_API_KEY=… swift test --filter SearchRealCloud
@Suite struct SearchRealCloud {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
    func interpretsSentences() async throws {
        let store = try temporaryStore()
        let cloud = Cloud(key: { _ in ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] })
        let searcher = Searcher(store: store, gateway: Gateway(embedder: FakeLocalEmbedder(), generators: [cloud], judges: [Jev(via: cloud)]))
        // Ambiguous sentences accept two readings: "视频网站怎么赚钱" and "明白人说的话" can be finding cards or asking a question (when asking, the cards it draws on gather too)
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
