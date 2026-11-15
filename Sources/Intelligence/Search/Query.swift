import Foundation
import NaturalLanguage
import Library

/// 一句话想要什么
public enum Intent: String, Codable, Sendable, CaseIterable {
    /// 找卡片：结果聚拢成一组拼贴
    case find
    /// 带主题的灵感：交给灵感，按主题挑
    case inspire
    /// 随机抽一张，解读显示在文字面板
    case draw
    /// 提问：回答显示在文字面板，依据的卡片聚拢到眼前
    case ask
}

/// 搜索和灵感从哪些卡片里找
public enum Scope: Hashable, Sendable {
    case all
    case board(Int64)
}

/// 筛选按钮的状态，和句子里解析出的条件合并成同一个查询
public struct Filters: Equatable, Sendable {
    public var days: Int?
    public var kinds: Set<Kind> = []
    public var color: ColorName?
    public var scope: Scope = .all

    public init() {}
}

/// 理解后的一句话：意图，加上语义部分和几种精确条件。语义交给向量和字面匹配，其余用来筛选
public struct Query: Equatable, Sendable {
    public var text: String
    public var intent: Intent = .find
    /// 去掉条件词以后要按意思找的部分；带主题的灵感里就是主题
    public var semantic = ""
    /// 字面匹配用的词
    public var tokens: [String] = []
    public var colors: [ColorName] = []
    /// 只看最近几天收的
    public var days: Int?
    public var kinds: Set<Kind> = []
    public var scope: Scope = .all
    /// 要看图才判断得了（「长得像狗的男人」）：精排时附上缩略图
    public var visual = false

    public init(text: String) { self.text = text }

    /// 找的是同一批卡：语义部分和各种条件都一样（意图、看不看图不算）
    public func sameSearch(as other: Query) -> Bool {
        semantic == other.semantic && Set(colors) == Set(other.colors) && days == other.days && kinds == other.kinds && scope == other.scope
    }

    /// 按意思找这句话：去掉首尾标点、转小写，再切成字面匹配的词。提问、讨论里的找卡都不让规则再拆条件
    public mutating func lookFor(_ text: String) {
        semantic = QueryRules.tidy(text.lowercased())
        tokens = QueryRules.tokenize(semantic)
    }

    /// 除了范围什么条件都没有
    public var isEmpty: Bool { semantic.isEmpty && colors.isEmpty && days == nil && kinds.isEmpty }

    func since(_ now: Date) -> Date? { days.map { now.addingTimeInterval(-Double($0) * 86_400) } }
}

/// 关键词规则：打字时即时给反馈，模型回来之前、没填密钥或离线时都靠它。
/// 选模型时的测试集也按这套规则拆查询，改了词表要重新验证搜索效果。
/// 判断模型回来以后也用它：模型说了算有没有条件、是哪种，规则负责认出是哪几个词、去掉它们，剩下的是要按意思找的内容
public enum QueryRules {
    /// 判断模型对一句话的结论（Searcher.questions）
    public struct Judged: Sendable, Equatable {
        public var intent: Intent
        /// 限定了收集时间
        public var timed: Bool
        /// 限定的类型；nil 是没限定
        public var kind: Kind?
        public var color: ColorName?
        public var visual: Bool
    }

    public static func parse(_ raw: String, filters: Filters = Filters(), judged: Judged? = nil) -> Query {
        var q = Query(text: raw)
        q.scope = filters.scope
        var text = raw.lowercased()

        // 意图：模型回来以后它说了算，没回来时规则只认整句就是指令的。
        // 指令词只在真是抽一张、要灵感时去掉；找卡片、提问用原句，「塔罗牌插画」里的「塔罗」是要找的东西
        q.intent = judged?.intent ?? intent(of: text)
        text = removingHints(of: q.intent, from: text)
        // 模型回来以后，它说了算有没有这种条件；没回来时规则认出什么算什么
        let timed = judged?.timed ?? true
        let counts = { (kinds: Set<Kind>) in judged.map { $0.kind.map(kinds.contains) ?? false } ?? true }
        let colored = { (color: ColorName) in judged.map { $0.color == color } ?? true }

        var days: Int?
        if timed {
            for (phrase, d) in timePhrases where text.containsWord(phrase) {
                days = min(days ?? d, d)
                text = text.removingWord(phrase)
            }
            // 模型说限定了时间、规则却认不出是几天的（「去年」「三月」）：不加时间条件，免得把要找的卡筛掉
        }
        if let d = filters.days { days = min(days ?? d, d) }
        q.days = days

        // 模型只选一类，句子里的词决定范围：「文章」不分网页、文档、文字
        for (word, kinds) in kindWords where text.containsWord(word) && counts(kinds) {
            q.kinds.formUnion(kinds)
            text = text.removingWord(word)
        }
        if let kind = judged?.kind, q.kinds.isEmpty { q.kinds = [kind] }
        q.kinds.formUnion(filters.kinds)

        for f in fillers { text = text.replacingOccurrences(of: f, with: " ") }

        // 颜色词保留在语义里（「绿色的界面」整体也有意思），同时单独记下来做像素筛选
        var leftover = text
        // 不算颜色条件的颜色字（「明白」的「白」）留在语义里
        for color in ColorName.allCases where colored(color) {
            for alias in color.aliases where leftover.containsWord(alias) {
                if !q.colors.contains(color) { q.colors.append(color) }
                leftover = leftover.removingWord(alias)
            }
        }
        if let color = judged?.color, !q.colors.contains(color) { q.colors.append(color) }
        if let c = filters.color, !q.colors.contains(c) { q.colors.append(c) }
        q.visual = judged?.visual ?? false

        // 只剩颜色词、连接词（「视频和文档」里的「和」）时不走语义，只按颜色、类型筛选
        let semantic = tokenize(leftover).isEmpty ? "" : tidy(text)
        q.semantic = semantic
        q.tokens = tokenize(semantic)
        return q
    }

    /// 没有模型时认意图。抽一张、要灵感只认整句就是指令的（「抽一张」「给我点灵感」）：句子里还有别的词，
    /// 多半是要找的东西（「灵感板参考」），当找卡片。提问只认说得很明白的，它不删词，依据的卡照样聚拢
    static func intent(of text: String) -> Intent {
        for (intent, commands, _) in hints where commands.contains(where: text.contains) {
            if tokenize(removingHints(of: intent, from: text)).isEmpty { return intent }
        }
        if questions.contains(where: text.contains) || text.hasSuffix("?") || text.hasSuffix("？") || text.hasSuffix("吗") { return .ask }
        return .find
    }

    /// 去掉这种意图的指令词，剩下的是主题；找卡片、提问没有指令词，原样返回
    static func removingHints(of intent: Intent, from text: String) -> String {
        guard let hint = hints.first(where: { $0.intent == intent }) else { return text }
        return (hint.commands + hint.companions).reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    /// 指令的说法。commands 单独成句就是指令；companions 是常跟着指令出现的词（「抽一张塔罗牌」），
    /// 单独出现时是要找的东西。长的排在前面，先被去掉
    private static let hints: [(intent: Intent, commands: [String], companions: [String])] = [
        (.draw, ["帮我抽一张", "抽一张", "抽张", "抽一下", "抽卡", "随便来一张", "随机一张"], ["塔罗牌", "塔罗"]),
        (.inspire, ["给我点灵感", "给点灵感", "来点灵感", "找点灵感"], ["灵感", "inspire", "inspiration"]),
    ]
    private static let questions = ["都在讲什么", "讲了什么", "说了什么", "是什么意思", "为什么", "有什么区别", "总结一下"]

    static let timePhrases: [(String, Int)] = [
        ("今天", 1), ("昨天", 2), ("这几天", 5), ("前几天", 7), ("本周", 7), ("这周", 7), ("这个星期", 7),
        ("上周", 14), ("上个星期", 14), ("本月", 31), ("这个月", 31), ("最近一个月", 31), ("上个月", 62), ("最近", 14), ("近期", 14),
        ("today", 1), ("this week", 7), ("recently", 14), ("recent", 14),
    ]
    /// 类型词。「文章」「笔记」在用户心里不分网页、文档还是自己写的长文，所以同时匹配几类
    static let kindWords: [(String, Set<Kind>)] = [
        ("引文", [.text]), ("语录", [.text]), ("名言", [.text]), ("句子", [.text]), ("文字", [.text]), ("quote", [.text]),
        ("文章", [.web, .document, .text]), ("笔记", [.web, .document, .text, .image]),
        ("链接", [.web]), ("网页", [.web]), ("link", [.web]),
        ("图片", [.image]), ("照片", [.image]), ("图像", [.image]), ("截图", [.image]), ("image", [.image]), ("photo", [.image]),
        ("文档", [.document]), ("pdf", [.document]), ("document", [.document]),
        ("视频", [.video]), ("影片", [.video]), ("video", [.video]),
        ("音频", [.audio]), ("录音", [.audio]), ("播客", [.audio]), ("audio", [.audio]),
    ]
    /// 只起连接作用、放进向量会稀释意思的词
    static let fillers = ["收集的", "收藏的", "收过的", "收的", "存的", "相关的", "相关", "内容", "的东西", "资料", "一些", "有关"]

    static func tidy(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).replacingOccurrences(of: "  ", with: " ")
    }

    private static let stopwords: Set<String> = ["的", "了", "和", "与", "及", "或", "跟", "还有", "以及", "a", "an", "the", "of", "and", "or"]

    /// 中文按词切分（「哲学」「界面」），英文按单词；去掉只起连接作用的词
    public static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let t = text[range].lowercased()
            if !stopwords.contains(t) { out.append(t) }
            return true
        }
        return out
    }
}

extension ColorName {
    /// 句子里怎么说这种颜色
    public var aliases: [String] {
        let zh: [String] = switch self {
        case .red: ["红色", "红"]
        case .orange: ["橙色", "橘色", "橙", "橘"]
        case .yellow: ["黄色", "黄"]
        case .green: ["绿色", "绿"]
        case .cyan: ["青色", "青绿", "青"]
        case .blue: ["蓝色", "蓝"]
        case .purple: ["紫色", "紫"]
        case .pink: ["粉色", "粉红", "粉"]
        case .brown: ["棕色", "褐色", "咖啡色", "棕", "褐"]
        case .black: ["黑色", "黑"]
        case .white: ["白色", "白"]
        case .gray: ["灰色", "灰"]
        }
        return zh + [rawValue]
    }
}

extension String {
    /// 中文按子串匹配；英文要整词匹配，免得 inspired 里的 red 被当成红色
    func containsWord(_ word: String) -> Bool {
        guard word.allSatisfy(\.isASCII) else { return contains(word) }
        return range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }

    func removingWord(_ word: String) -> String {
        guard word.allSatisfy(\.isASCII) else { return replacingOccurrences(of: word, with: " ") }
        return replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", with: " ", options: .regularExpression)
    }
}
