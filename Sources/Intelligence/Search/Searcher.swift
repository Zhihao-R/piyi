import Foundation
import Library

/// Search: a sentence → intent and conditions → cards and their order, or a passage of text.
/// The canvas decides where they go; this only gives "which cards, in what order".
/// All models go through the gateway: intent and reranking use judging; condition extraction, answers and interpretations use generation. Offline or without a key, only rules and local embeddings are used, without waiting on the network
public actor Searcher {
    let store: Store
    let gateway: Gateway
    private var cards: [SearchCard] = []
    private var stale = true
    /// Snapshot being read: several callers arriving together wait on the same read, never getting an empty or half-stale one
    private var loading: Task<[SearchCard]?, Never>?

    public init(store: Store, gateway: Gateway) {
        self.store = store
        self.gateway = gateway
    }

    /// The library changed (card collected, a batch understood, card deleted): reread on next use
    public nonisolated func invalidate() { Task { await markStale() } }

    private func markStale() {
        stale = true
        judging = []
    }

    /// For tests: swap in a set of cards directly, without reading the library
    func replaceCards(_ cards: [SearchCard]) {
        self.cards = cards
        stale = false
    }

    /// Current snapshot of cards; reread if the library changed (tens of milliseconds for a few thousand cards)
    public func snapshot() async -> [SearchCard] {
        if let loading { return await loading.value ?? cards }
        guard stale else { return cards }
        stale = false
        let (store, model) = (store, gateway.embeddingModel)
        let task = Task { try? await store.searchRows().map { Self.searchCard($0, model: model) } }
        loading = task
        let fresh = await task.value
        loading = nil
        if let fresh { cards = fresh } else { stale = true }
        return cards
    }

    static func searchCard(_ row: SearchRow, model: String?) -> SearchCard {
        let card = row.card
        // Literal matching searches all body text and subtitles: the word you remember is found whether it's thousands of characters in or in some sentence of a video
        let content = card.text ?? card.fullBody.map(Article.plain) ?? ""
        let text = [card.displayTitle, card.title, card.caption, card.detail, card.tags.joined(separator: " "), card.format, content, card.source]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let colors = card.colors.flatMap(ColorProfile.init(json:))?.share
        let vector = row.model == model ? row.vector.map { $0.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } : nil
        let brief = Self.brief(label: card.format ?? Prompt.label(card.kind), title: card.displayTitle, caption: card.caption,
                               detail: card.detail, tags: card.tags, excerpt: content)
        return SearchCard(id: card.id!, kind: card.kind, collectedAt: card.collectedAt, text: text, colors: colors, vector: vector,
                          boards: row.boards, brief: brief, cover: card.cover)
    }

    /// One line for the model: type, title, description, detailed description, tags; body text opening when there's no description
    static func brief(label: String, title: String, caption: String?, detail: String?, tags: [String], excerpt: String) -> String {
        var brief = "[\(label)] \(title)"
        if let caption { brief += "；\(caption)" }
        // The detailed description says what's in the image: "a white cat", "a woman in a red headscarf" can only be judged with it, without looking at the image
        if let detail { brief += "；\(detail.prefix(200))" }
        if !tags.isEmpty { brief += "；标签：\(tags.prefix(6).joined(separator: "、"))" }
        if caption == nil, !excerpt.isEmpty { brief += "；\(excerpt.prefix(120))" }
        return brief
    }

    // MARK: While typing

    /// Cards with a literal hit: lit up in place while typing, without moving
    public func literal(_ q: Query) async -> [Int64] {
        Ranking.literal(await snapshot(), q)
    }

    // MARK: Understanding the sentence

    /// Whether judging is usable: online, with a usable provider. Understanding a sentence and reranking rely on it
    func canJudge(online: Bool) async -> Bool {
        guard online else { return false }
        return gateway.canJudge
    }

    /// Whether generation is usable. Interpreting a drawn card and answering questions rely on it
    func canGenerate(online: Bool) async -> Bool {
        guard online else { return false }
        return gateway.canGenerate
    }

    /// Hand to the model to understand: one request asks the intent, and whether time, type or color is limited and whether images need to be seen.
    /// The judge model can't write text, so rules remove condition words based on its conclusions to get what to search for; if it doesn't return (model unavailable, timeout), the rules are used throughout.
    /// While waiting, rerank by the conditions the rules split out, then judge any new candidates after understanding: it's handed off when you stop typing, so by the time you press Return judging is usually done
    public func interpret(_ text: String, filters: Filters, online: Bool) async -> Query {
        let rules = QueryRules.parse(text, filters: filters)
        guard await canJudge(online: online) else { return rules }
        prejudge(rules)
        let gateway = gateway
        guard let verdicts = await within(Self.interpretTimeout, {
            try await gateway.judge([(Self.said, text)], Self.questions)
        }) else { return rules }
        // No confidence threshold for intent: falling back to rules when unsure only does worse (tested when choosing models)
        let q = QueryRules.parse(text, filters: filters, judged: Self.judged(verdicts))
        prejudge(q)
        return q
    }

    /// Rerank the cards to find in the background first, recording judged ones in judging
    private func prejudge(_ q: Query) {
        guard q.intent == .find, !q.semantic.isEmpty else { return }
        Task { _ = await rerank(await coarse(q), for: q) }
    }

    static let said = "用户在收藏夹的搜索框里输入的一句话"

    /// The questions asked to understand a sentence: intent, time, type, color, whether to see images, in a fixed order that judged is read in.
    /// The wording of the first four was tried on the test set when choosing the model; retest if you change it
    static let questions: [Question] = [
        Question("这句话想做什么？", .choice([
            (Intent.find.rawValue, "找卡片：想从收藏里找出符合描述的卡片"),
            (Intent.inspire.rawValue, "带主题的灵感：想要围绕某个主题的创作点子或启发"),
            (Intent.draw.rawValue, "随机抽一张：想随机抽一张卡，比如占卜、今日卡片"),
            (Intent.ask.rawValue, "提问：想就收藏的内容得到一段文字回答"),
        ])),
        Question("这句话是否要求按收集时间筛选卡片（比如「上周收的」「最近存的」）？只是句子里出现了时间词、并不是在限定收集时间的（比如「今天吃什么」）不算。", .yesNo),
        Question("这句话是否限定了要哪一类卡片？只是句子里出现了类型词、并不是在限定卡片类型的（比如「视频网站怎么赚钱」是在找讲这个话题的内容）算没有限定。", .choice([
            ("none", "没有限定类型"), (Kind.image.rawValue, "图片、照片、画"), (Kind.text.rawValue, "文字、句子、随手记"),
            (Kind.web.rawValue, "网页、文章链接"), (Kind.document.rawValue, "PDF、Word 等文档"), (Kind.video.rawValue, "视频"),
            (Kind.audio.rawValue, "音频、播客、录音"),
        ])),
        Question("这句话是否限定了画面的主要颜色？只是字面上带颜色字的（比如「明白」「红楼梦」）算没有限定。",
                 .choice([("none", "没有限定颜色")] + ColorName.allCases.map { ($0.rawValue, $0.aliases[0].replacingOccurrences(of: "色", with: "")) })),
        // This question wasn't tested when choosing models. Wordings were compared on 16 sentences: asking "must the image be seen" made Jev call "cat" and "tarot cards" a coin toss too; asking this way separates them
        Question("这句话找的是画面「像什么」「构图」「画风」这类只有看图才判断得了的特征吗？画面里有什么人、物、颜色、场景，卡片的文字描述里都写了，不算。", .yesNo),
    ]

    static func judged(_ v: [Verdict]) -> QueryRules.Judged {
        let key = { (i: Int) in questions[i].key(of: v[i]) ?? "" }
        return QueryRules.Judged(intent: Intent(rawValue: key(0)) ?? .find, timed: v[1].yes,
                                 kind: Kind(rawValue: key(2)), color: ColorName(rawValue: key(3)), visual: v[4].yes)
    }

    static let interpretTimeout = 3.0, rerankTimeout = 10.0, visualTimeout = 20.0, readingTimeout = 20.0

    // MARK: Finding cards

    /// Rough search: embedding and literal scores together, cut by threshold
    public func coarse(_ q: Query) async -> (shown: [Int64], ranked: [Int64]) {
        let cards = await snapshot()
        let vector = q.semantic.isEmpty ? nil : try? await gateway.embed(q.semantic, as: .query)
        let scored = Ranking.scored(cards, q, semantic: vector)
        return (Ranking.shown(scored, semantic: vector != nil), scored.map(\.id))
    }

    /// Whether cloud reranking follows the rough search: there must be content to find by meaning, and the judge model must be usable
    private func refines(_ q: Query, online: Bool) async -> Bool {
        guard !q.semantic.isEmpty else { return false }
        return await canJudge(online: online)
    }

    /// Candidates for reranking: those above the threshold, plus a batch just below it, so reranking can recover ones that were missed
    static func candidates(_ shown: [Int64], _ ranked: [Int64], limit: Int = 30) -> [Int64] {
        var seen = Set<Int64>()
        return (shown + ranked.prefix(limit)).filter { seen.insert($0).inserted }
    }

    /// Find cards: rough search, then reranking when the model is usable. Returns the cards to gather, in order
    public func find(_ q: Query, online: Bool) async -> [Int64] {
        let found = await coarse(q)
        guard await refines(q, online: online) else { return found.shown }
        return Array(await rerank(found, for: q).prefix(Ranking.maxResults))
    }

    /// Find cards, delivering results in batches, with the view moving only when the set of cards changes: the local rough search comes first; when cloud reranking returns,
    /// if the hits are the same set of cards nothing more is delivered (keeping the local order); only a different set is delivered.
    /// gathered is what's already gathered in front of you (the batch found by rules on Return): if cloud reranking is about to arrive, wait for it rather than move once more for an intermediate result
    public nonisolated func finding(_ q: Query, online: Bool, over gathered: [Int64] = []) -> AsyncStream<[Int64]> {
        AsyncStream { continuation in
            let task = Task {
                var gathered = gathered
                func give(_ cards: [Int64]) {
                    guard Set(cards) != Set(gathered) else { return }
                    gathered = cards
                    continuation.yield(cards)
                }
                let found = await coarse(q)
                let refining = await refines(q, online: online)
                if gathered.isEmpty || !refining { give(found.shown) }
                if refining { give(Array(await rerank(found, for: q).prefix(Ranking.maxResults))) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reranking: judge how relevant each candidate is to the sentence, keep "relevant" and above, ordered by relevance and then by rough-search rank.
    /// Cards judged earlier for this sentence (judged first by the rules' conditions while it was being understood) are included if they meet the current conditions, so none are missed when the model rewrites what to find.
    /// Cards not judged: those above the threshold are inserted back by their rough-search rank
    func rerank(_ found: (shown: [Int64], ranked: [Int64]), for q: Query) async -> [Int64] {
        let order = Dictionary(uniqueKeysWithValues: found.ranked.enumerated().map { ($1, $0) })
        let choices = await judge(await judgeable(found), for: q)
        let kept = choices.filter { $1 >= 2 && order[$0] != nil }
            .sorted { $0.value != $1.value ? $0.value > $1.value : order[$0.key]! < order[$1.key]! }
            .map(\.key)
        return Self.restoring(found.shown, into: kept) { choices[$0] != nil }
    }

    /// Candidates handed to the judge model
    private func judgeable(_ found: (shown: [Int64], ranked: [Int64])) async -> [SearchCard] {
        let byID = Dictionary(uniqueKeysWithValues: await snapshot().map { ($0.id, $0) })
        return Self.candidates(found.shown, found.ranked).compactMap { byID[$0] }
    }

    /// Cards not judged: those above the threshold are inserted back by their rough-search rank
    static func restoring(_ shown: [Int64], into kept: [Int64], judged: (Int64) -> Bool) -> [Int64] {
        var result = kept
        for (i, id) in shown.enumerated() where !judged(id) { result.insert(id, at: min(i, result.count)) }
        return result
    }

    /// The sentence and whether to see images: the question reranking asks the model depends only on these two, not on conditions like time and type
    private struct Asked: Equatable {
        var text: String
        var visual: Bool
    }

    /// Each card's judgment for the last few sentences (finished or in progress). Typing with pauses understands several sentences in turn; each is recorded separately without overwriting
    private var judging: [(asked: Asked, tasks: [Int64: Task<[Int64: Int], Never>])] = []

    /// Judge card by card (options in relevance), returned together with earlier judgments for this sentence; ones not judged (timeout, error) are left out.
    /// Ones in progress are waited on, ones never asked are asked again right away, both at the same time, without queuing
    func judge(_ cards: [SearchCard], for q: Query) async -> [Int64: Int] {
        let asked = Asked(text: q.text, visual: q.visual)
        var tasks = judging.first { $0.asked == asked }?.tasks ?? [:]
        let missing = cards.filter { tasks[$0.id] == nil }
        if !missing.isEmpty {
            let (gateway, files) = (gateway, store.files)
            let task = Task {
                guard let choices = await Self.ask(missing, for: q, gateway: gateway, files: files) else { return [Int64: Int]() }
                return Dictionary(uniqueKeysWithValues: zip(missing.map(\.id), choices))
            }
            for card in missing { tasks[card.id] = task }
            judging = [(asked, tasks)] + judging.filter { $0.asked != asked }.prefix(3)
        }
        var known: [Int64: Int] = [:]
        for task in Set(tasks.values) { known.merge(await task.value) { $1 } }
        // Forget the ones not judged; ask again next time
        for (i, entry) in judging.enumerated() where entry.asked == asked {
            judging[i].tasks = entry.tasks.filter { known[$0.key] != nil || tasks[$0.key] != $0.value }
        }
        return known
    }

    /// Ask the model once. Queries that need the image to judge attach small images
    static func ask(_ cards: [SearchCard], for q: Query, gateway: Gateway, files: FileStore) async -> [Int]? {
        var pictures: [Data] = []
        let items = cards.map { card in
            guard q.visual, pictures.count < Self.pictures, let cover = card.cover, let jpeg = Prompt.glance(cover, files: files) else { return card.brief }
            pictures.append(jpeg)
            return card.brief + "（附图 \(pictures.count)）"
        }
        let question = Question("这张卡片和这次搜索有多相关？" + (pictures.isEmpty ? "" : "有附图的请看图判断。"), .grade(relevance))
        let attached = pictures
        // Seeing images is much slower (4–11 seconds measured): give it a longer time limit. Jev can't see images; with images attached the gateway hands it to a generation model that can
        return await within(q.visual ? visualTimeout : rerankTimeout) {
            try await gateway.judge(each: items, question, about: [("搜索", q.text)], images: attached).map(\.choice)
        }
    }

    /// Relevance, from low to high. Keep "relevant" and above
    static let relevance = ["无关", "沾点边", "相关", "正是要找的"]
    /// At most how many images to attach for reranking
    static let pictures = 12

    /// Cards related to a topic (inspiration with a topic picks from here): rough search, then when the model is usable ask card by card "is this directly related to the topic".
    /// This is the only place judging splits off: inspiration is prepared in the background with nobody waiting, so unconfident ones go to the generation model for a careful judgment (selection data: topic filtering rose from 0.771 to 0.903, 0.886 measured in the app).
    /// The gateway limits careful judgments item by item; ones that time out keep the first-pass conclusion
    func related(_ q: Query) async -> [Int64] {
        let found = await coarse(q)
        let open = await judgeable(found)
        guard !open.isEmpty else { return found.shown }
        let topic = q.semantic.isEmpty ? q.text : q.semantic
        let verdicts = (try? await gateway.judge(each: open.map(\.brief), Self.themed, about: [("灵感主题", topic)], recheck: true)) ?? []
        let judged = Set(zip(open, verdicts).map(\.0.id))
        return Self.restoring(found.shown, into: zip(open, verdicts).filter { $1.yes }.map(\.0.id)) { judged.contains($0) }
    }

    /// The wording was tried on the test set when choosing the model; retest if you change it
    static let themed = Question("这张卡片的内容和这个主题直接相关吗？只能牵强联想到的不算。", .yesNo)

    // MARK: Text panel

    /// Result of drawing a card or asking a question: a passage of text and the cards it's based on
    public struct Reading: Sendable, Equatable {
        public var text: String?
        public var cards: [Int64]
    }

    /// Draw one card at random as the "card", with an interpretation when the model is usable. The topic in the sentence is only used for writing the interpretation, not to narrow the pool; time, type, color and scope filter as usual
    public func draw(_ q: Query, online: Bool) async -> Reading? {
        var conditions = q
        conditions.semantic = ""
        let pool = Ranking.eligible(await snapshot(), conditions, now: .now).filter { Ranking.colorOK($0, conditions) }
        guard let card = pool.randomElement() else { return nil }
        guard await canGenerate(online: online) else { return Reading(text: nil, cards: [card.id]) }
        let picture = card.cover.flatMap { Prompt.glance($0, files: store.files) }
        let prompt = """
        用户说：「\(q.text)」。从他的收藏里随机抽到了这一张，把它当作一张牌来解读\(picture == nil ? "" : "（附图是这张卡）")：
        \(card.brief)

        写法：
        \(Writing.Part.draw.style)
        另外：用和用户这句话相同的语言写，看不出来时用\(Writing.language)；换了语言篇幅照样。
        只输出 JSON：{"text":"解读"}
        """
        struct Reply: Decodable { var text: String }
        let gateway = gateway
        let reply = await within(Self.readingTimeout) {
            try await gateway.generate(prompt, images: picture.map { [$0] } ?? [], as: Reply.self)
        }
        return Reading(text: reply?.text, cards: [card.id])
    }

    /// Question: find related cards, have the model answer based on them, and say which ones it relied on
    public func ask(_ q: Query, online: Bool) async -> Reading {
        var search = q
        search.lookFor(q.semantic.isEmpty ? q.text : q.semantic)
        let (shown, ranked) = await coarse(search)
        guard await canGenerate(online: online) else { return Reading(text: nil, cards: shown) }
        let byID = Dictionary(uniqueKeysWithValues: await snapshot().map { ($0.id, $0) })
        let sources = Array(Self.candidates(shown, ranked, limit: 12).compactMap { byID[$0] }.prefix(16))
        guard !sources.isEmpty else { return Reading(text: nil, cards: shown) }
        let prompt = """
        用户问：「\(q.text)」
        下面是从他的收藏里找到的卡片。只根据这些卡片回答；卡片里没有的就直说没收过相关的。
        写法：
        \(Writing.Part.answer.style)
        另外：用和用户这句话相同的语言写，看不出来时用\(Writing.language)；换了语言篇幅照样。

        \(sources.enumerated().map { "\($0.offset + 1). \($0.element.brief)" }.joined(separator: "\n"))

        只输出 JSON：{"text":"回答","cards":[回答依据的卡片编号]}
        """
        struct Reply: Decodable { var text: String; var cards: [Int]? }
        let gateway = gateway
        guard let reply = await within(Self.readingTimeout, { try await gateway.generate(prompt, as: Reply.self) }) else {
            return Reading(text: nil, cards: shown)
        }
        let cited = (reply.cards ?? []).compactMap { sources.indices.contains($0 - 1) ? sources[$0 - 1].id : nil }
        return Reading(text: reply.text, cards: cited.isEmpty ? shown : cited)
    }
}

/// Do one thing with a time limit: returns nil on timeout or error, and cancels what isn't finished
func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await work() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
