import Foundation
import Library

/// 搜索：一句话 → 意图和条件 → 卡片、顺序，或一段文字。
/// 摆在哪由画布决定，这里只给出「哪些卡片、什么顺序」。
/// 模型都从出口走：意图和精排用判断能力，条件抽取、回答、解读用生成能力；离线或没填密钥时只用规则和本机向量，不等网络
public actor Searcher {
    let store: Store
    let gateway: Gateway
    private var cards: [SearchCard] = []
    private var stale = true
    /// 正在读的快照：同时来的几个调用者等同一次读取，不会拿到空的或半旧的
    private var loading: Task<[SearchCard]?, Never>?

    public init(store: Store, gateway: Gateway) {
        self.store = store
        self.gateway = gateway
    }

    /// 资料库变了（收了卡、理解完一批、删了卡）：下次用时重读
    public nonisolated func invalidate() { Task { await markStale() } }

    private func markStale() {
        stale = true
        judging = []
    }

    /// 测试用：直接换一份卡片，不读资料库
    func replaceCards(_ cards: [SearchCard]) {
        self.cards = cards
        stale = false
    }

    /// 当前的卡片快照；资料库变过就重读一遍（几千张卡几十毫秒）
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
        // 字面匹配查全部正文和字幕：记得的那个词在第几千字、在视频的哪一句都找得到
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

    /// 给模型看的一行：类型、标题、描述、详细描述、标签；没有描述时用正文开头
    static func brief(label: String, title: String, caption: String?, detail: String?, tags: [String], excerpt: String) -> String {
        var brief = "[\(label)] \(title)"
        if let caption { brief += "；\(caption)" }
        // 详细描述写了画面里有什么：「白色的猫」「戴红头巾的女人」靠它才判断得了，不必看图
        if let detail { brief += "；\(detail.prefix(200))" }
        if !tags.isEmpty { brief += "；标签：\(tags.prefix(6).joined(separator: "、"))" }
        if caption == nil, !excerpt.isEmpty { brief += "；\(excerpt.prefix(120))" }
        return brief
    }

    // MARK: 打字时

    /// 字面命中的卡：打字时原地亮起，不动位置
    public func literal(_ q: Query) async -> [Int64] {
        Ranking.literal(await snapshot(), q)
    }

    // MARK: 理解这句话

    /// 判断能力能不能用：在线，并且有能用的服务方。理解一句话、精排靠它
    func canJudge(online: Bool) async -> Bool {
        guard online else { return false }
        return gateway.canJudge
    }

    /// 生成能力能不能用。抽一张的解读、回答提问靠它
    func canGenerate(online: Bool) async -> Bool {
        guard online else { return false }
        return gateway.canGenerate
    }

    /// 交给模型理解：一次请求问完意图，以及有没有限定时间、类型、颜色，要不要看图。
    /// 判断模型写不出文字，要找的内容由规则按它的结论去掉条件词；没回来（模型不可用、超时）就全用规则的。
    /// 等它的同时先按规则拆出的条件精排，理解完再补判新冒出来的候选：停手后交给它理解，按回车时多半已经判完
    public func interpret(_ text: String, filters: Filters, online: Bool) async -> Query {
        let rules = QueryRules.parse(text, filters: filters)
        guard await canJudge(online: online) else { return rules }
        prejudge(rules)
        let gateway = gateway
        guard let verdicts = await within(Self.interpretTimeout, {
            try await gateway.judge([(Self.said, text)], Self.questions)
        }) else { return rules }
        // 意图不设把握线：把握不够时改用规则的只会更差（选模型时的测试）
        let q = QueryRules.parse(text, filters: filters, judged: Self.judged(verdicts))
        prejudge(q)
        return q
    }

    /// 在后台先把要找的卡精排掉，判过的记在 judging 里
    private func prejudge(_ q: Query) {
        guard q.intent == .find, !q.semantic.isEmpty else { return }
        Task { _ = await rerank(await coarse(q), for: q) }
    }

    static let said = "用户在收藏夹的搜索框里输入的一句话"

    /// 理解一句话问的几道题：意图、时间、类型、颜色、要不要看图，顺序固定，judged 按这个顺序读。
    /// 前四道的问法是选模型时在测试集上试过的，改了要重测
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
        // 选型时没测这一题。问法在 16 句上比过：问「是否必须看图」时 Jev 把「猫」「塔罗牌」也判成五五开，这样问分得开
        Question("这句话找的是画面「像什么」「构图」「画风」这类只有看图才判断得了的特征吗？画面里有什么人、物、颜色、场景，卡片的文字描述里都写了，不算。", .yesNo),
    ]

    static func judged(_ v: [Verdict]) -> QueryRules.Judged {
        let key = { (i: Int) in questions[i].key(of: v[i]) ?? "" }
        return QueryRules.Judged(intent: Intent(rawValue: key(0)) ?? .find, timed: v[1].yes,
                                 kind: Kind(rawValue: key(2)), color: ColorName(rawValue: key(3)), visual: v[4].yes)
    }

    static let interpretTimeout = 3.0, rerankTimeout = 10.0, visualTimeout = 20.0, readingTimeout = 20.0

    // MARK: 找卡片

    /// 粗找：向量和字面一起打分，按分数线截
    public func coarse(_ q: Query) async -> (shown: [Int64], ranked: [Int64]) {
        let cards = await snapshot()
        let vector = q.semantic.isEmpty ? nil : try? await gateway.embed(q.semantic, as: .query)
        let scored = Ranking.scored(cards, q, semantic: vector)
        return (Ranking.shown(scored, semantic: vector != nil), scored.map(\.id))
    }

    /// 粗找完还有没有云端精排：要有按意思找的内容，判断模型也用得上
    private func refines(_ q: Query, online: Bool) async -> Bool {
        guard !q.semantic.isEmpty else { return false }
        return await canJudge(online: online)
    }

    /// 精排的候选：分数线以上的，加上线下面紧挨着的一批，精排有机会把漏掉的捞回来
    static func candidates(_ shown: [Int64], _ ranked: [Int64], limit: Int = 30) -> [Int64] {
        var seen = Set<Int64>()
        return (shown + ranked.prefix(limit)).filter { seen.insert($0).inserted }
    }

    /// 找卡片：粗找，模型能用时再精排。返回要聚拢的卡，按顺序
    public func find(_ q: Query, online: Bool) async -> [Int64] {
        let found = await coarse(q)
        guard await refines(q, online: online) else { return found.shown }
        return Array(await rerank(found, for: q).prefix(Ranking.maxResults))
    }

    /// 找卡片，结果分批给，画面只在换了一批卡时才动：本机粗找的先给；云端精排回来，
    /// 命中的还是同一批卡就不再给（保持本机的顺序），不是同一批才给新的。
    /// gathered 是眼前已经聚拢着的（回车时先按规则找的那批）：云端精排马上要来时等它，不为中间结果多动一次
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

    /// 精排：候选逐张判断和这句话有多相关，留下「相关」以上的，先按相关程度、再按粗找的名次排。
    /// 这句话早先判过的卡（理解它时按规则的条件先判的）只要符合现在的条件也算进来，模型改写了要找的内容时漏不掉。
    /// 没判出来的卡：分数线以上的按粗找时的名次插回去
    func rerank(_ found: (shown: [Int64], ranked: [Int64]), for q: Query) async -> [Int64] {
        let order = Dictionary(uniqueKeysWithValues: found.ranked.enumerated().map { ($1, $0) })
        let choices = await judge(await judgeable(found), for: q)
        let kept = choices.filter { $1 >= 2 && order[$0] != nil }
            .sorted { $0.value != $1.value ? $0.value > $1.value : order[$0.key]! < order[$1.key]! }
            .map(\.key)
        return Self.restoring(found.shown, into: kept) { choices[$0] != nil }
    }

    /// 交给判断模型的候选
    private func judgeable(_ found: (shown: [Int64], ranked: [Int64])) async -> [SearchCard] {
        let byID = Dictionary(uniqueKeysWithValues: await snapshot().map { ($0.id, $0) })
        return Self.candidates(found.shown, found.ranked).compactMap { byID[$0] }
    }

    /// 没判出来的卡：分数线以上的按粗找时的名次插回去
    static func restoring(_ shown: [Int64], into kept: [Int64], judged: (Int64) -> Bool) -> [Int64] {
        var result = kept
        for (i, id) in shown.enumerated() where !judged(id) { result.insert(id, at: min(i, result.count)) }
        return result
    }

    /// 一句话、看不看图：精排问模型的问题只由这两样决定，和时间、类型这些条件无关
    private struct Asked: Equatable {
        var text: String
        var visual: Bool
    }

    /// 最近几句话里每张卡的判断（问完的或正在问的）。边打边停会先后理解好几句，各记各的，互不覆盖
    private var judging: [(asked: Asked, tasks: [Int64: Task<[Int64: Int], Never>])] = []

    /// 逐张判断（选项见 relevance），和这句话早先判过的合在一起返回；没判出来（超时、出错）的不在里面。
    /// 正在问的等它，没问过的马上另问一次，两边同时进行，不排队
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
        // 没判出来的忘掉，下次再问
        for (i, entry) in judging.enumerated() where entry.asked == asked {
            judging[i].tasks = entry.tasks.filter { known[$0.key] != nil || tasks[$0.key] != $0.value }
        }
        return known
    }

    /// 问一次模型。要看图才判断得了的查询附上小图
    static func ask(_ cards: [SearchCard], for q: Query, gateway: Gateway, files: FileStore) async -> [Int]? {
        var pictures: [Data] = []
        let items = cards.map { card in
            guard q.visual, pictures.count < Self.pictures, let cover = card.cover, let jpeg = Prompt.glance(cover, files: files) else { return card.brief }
            pictures.append(jpeg)
            return card.brief + "（附图 \(pictures.count)）"
        }
        let question = Question("这张卡片和这次搜索有多相关？" + (pictures.isEmpty ? "" : "有附图的请看图判断。"), .grade(relevance))
        let attached = pictures
        // 看图慢得多（实测 4～11 秒）：给它更长的限时。Jev 不能看图，有附图时出口交给能看图的生成模型
        return await within(q.visual ? visualTimeout : rerankTimeout) {
            try await gateway.judge(each: items, question, about: [("搜索", q.text)], images: attached).map(\.choice)
        }
    }

    /// 相关程度，由低到高。留下「相关」以上的
    static let relevance = ["无关", "沾点边", "相关", "正是要找的"]
    /// 精排最多附几张图
    static let pictures = 12

    /// 和主题相关的卡（带主题的灵感从这里挑）：粗找，模型能用时逐张问「和主题直接相关吗」。
    /// 判断能力里只有这里分流：灵感在后台备着、不用人等，把握不够的交给生成模型仔细判（选型数据：主题筛选从 0.771 升到 0.903，App 实测 0.886）。
    /// 仔细判由出口逐条限时，超时的留着第一遍的结论
    func related(_ q: Query) async -> [Int64] {
        let found = await coarse(q)
        let open = await judgeable(found)
        guard !open.isEmpty else { return found.shown }
        let topic = q.semantic.isEmpty ? q.text : q.semantic
        let verdicts = (try? await gateway.judge(each: open.map(\.brief), Self.themed, about: [("灵感主题", topic)], recheck: true)) ?? []
        let judged = Set(zip(open, verdicts).map(\.0.id))
        return Self.restoring(found.shown, into: zip(open, verdicts).filter { $1.yes }.map(\.0.id)) { judged.contains($0) }
    }

    /// 问法是选模型时在测试集上试过的，改了要重测
    static let themed = Question("这张卡片的内容和这个主题直接相关吗？只能牵强联想到的不算。", .yesNo)

    // MARK: 文字面板

    /// 抽一张、提问的结果：一段文字和它依据的卡
    public struct Reading: Sendable, Equatable {
        public var text: String?
        public var cards: [Int64]
    }

    /// 随机抽一张当「牌」，模型能用时给出解读。句子里的主题只用来写解读，不缩小卡池；时间、类型、颜色、范围照常筛
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

        解读要从这张卡的具体细节出发，回应用户这句话，不写空话。三到五句，不超过 150 字。
        只输出 JSON：{"text":"解读"}
        """
        struct Reply: Decodable { var text: String }
        let gateway = gateway
        let reply = await within(Self.readingTimeout) {
            try await gateway.generate(prompt, images: picture.map { [$0] } ?? [], as: Reply.self)
        }
        return Reading(text: reply?.text, cards: [card.id])
    }

    /// 提问：找出相关的卡，让模型据此回答，并说出依据了哪几张
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
        下面是从他的收藏里找到的卡片。只根据这些卡片回答，指向具体的卡片和细节；卡片里没有的就直说没收过相关的。不超过 200 字。

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

/// 限时做一件事：超时、出错都返回 nil，并取消还没做完的
func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await work() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
