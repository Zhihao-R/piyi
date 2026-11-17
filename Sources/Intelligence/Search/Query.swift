import Foundation
import NaturalLanguage
import Library

/// What a sentence wants
public enum Intent: String, Codable, Sendable, CaseIterable {
    /// Find cards: results gather into a collage
    case find
    /// Inspiration with a topic: handed to Inspirer, picking by topic
    case inspire
    /// Draw one card at random, with the interpretation shown in the text panel
    case draw
    /// Question: the answer shows in the text panel, and the cards it's based on gather in front of you
    case ask
}

/// Which cards search and inspiration look through
public enum Scope: Hashable, Sendable {
    case all
    case board(Int64)
}

/// State of the filter buttons, merged with conditions parsed from the sentence into one query
public struct Filters: Equatable, Sendable {
    public var days: Int?
    public var kinds: Set<Kind> = []
    public var color: ColorName?
    public var scope: Scope = .all

    public init() {}
}

/// A sentence after understanding: intent, plus a semantic part and several exact conditions. The semantic part goes to embeddings and literal matching; the rest is used for filtering
public struct Query: Equatable, Sendable {
    public var text: String
    public var intent: Intent = .find
    /// What's left to find by meaning after removing condition words; for inspiration with a topic, it's the topic
    public var semantic = ""
    /// Words for literal matching
    public var tokens: [String] = []
    public var colors: [ColorName] = []
    /// Only look at what was collected in the last few days
    public var days: Int?
    public var kinds: Set<Kind> = []
    public var scope: Scope = .all
    /// Needs the image to judge ("a man who looks like a dog"): attach thumbnails during reranking
    public var visual = false

    public init(text: String) { self.text = text }

    /// Looking for the same set of cards: the semantic part and all conditions are the same (intent and whether to see images don't count)
    public func sameSearch(as other: Query) -> Bool {
        semantic == other.semantic && Set(colors) == Set(other.colors) && days == other.days && kinds == other.kinds && scope == other.scope
    }

    /// Find this sentence by meaning: strip leading and trailing punctuation, lowercase, then split into words for literal matching. Questions and Find cards in discussions don't let the rules split out conditions again
    public mutating func lookFor(_ text: String) {
        semantic = QueryRules.tidy(text.lowercased())
        tokens = QueryRules.tokenize(semantic)
    }

    /// No conditions other than scope
    public var isEmpty: Bool { semantic.isEmpty && colors.isEmpty && days == nil && kinds.isEmpty }

    func since(_ now: Date) -> Date? { days.map { now.addingTimeInterval(-Double($0) * 86_400) } }
}

/// Keyword rules: give instant feedback while typing, and are relied on before the model returns, with no key, or offline.
/// The test set for choosing models also splits queries by these rules; changing the word lists means re-checking search quality.
/// Also used after the judge model returns: the model decides whether there are conditions and which kind, the rules find which words they are and remove them, and what's left is the content to find by meaning
public enum QueryRules {
    /// The judge model's conclusions about a sentence (Searcher.questions)
    public struct Judged: Sendable, Equatable {
        public var intent: Intent
        /// Limited by collection time
        public var timed: Bool
        /// The type limited to; nil means no limit
        public var kind: Kind?
        public var color: ColorName?
        public var visual: Bool
    }

    public static func parse(_ raw: String, filters: Filters = Filters(), judged: Judged? = nil) -> Query {
        var q = Query(text: raw)
        q.scope = filters.scope
        var text = raw.lowercased()

        // Intent: once the model returns it decides; before that, the rules only recognize a sentence that is entirely a command.
        // Command words are only removed when it really is drawing a card or asking for inspiration; finding cards and questions use the original sentence, since 「塔罗」 in 「塔罗牌插画」 (tarot illustrations) is what's being searched for
        q.intent = judged?.intent ?? intent(of: text)
        text = removingHints(of: q.intent, from: text)
        // Once the model returns, it decides whether this kind of condition exists; before that, whatever the rules recognize counts
        let timed = judged?.timed ?? true
        let counts = { (kinds: Set<Kind>) in judged.map { $0.kind.map(kinds.contains) ?? false } ?? true }
        let colored = { (color: ColorName) in judged.map { $0.color == color } ?? true }

        var days: Int?
        if timed {
            for (phrase, d) in timePhrases where text.containsWord(phrase) {
                days = min(days ?? d, d)
                text = text.removingWord(phrase)
            }
            // The model says time is limited but the rules can't tell how many days (「去年」 last year, 「三月」 March): add no time condition, so the wanted cards aren't filtered out
        }
        if let d = filters.days { days = min(days ?? d, d) }
        q.days = days

        // The model picks only one category; the words in the sentence decide the range: 「文章」 (article) doesn't distinguish web pages, documents, or text
        for (word, kinds) in kindWords where text.containsWord(word) && counts(kinds) {
            q.kinds.formUnion(kinds)
            text = text.removingWord(word)
        }
        if let kind = judged?.kind, q.kinds.isEmpty { q.kinds = [kind] }
        q.kinds.formUnion(filters.kinds)

        for f in fillers { text = text.replacingOccurrences(of: f, with: " ") }

        // Color words stay in the semantic part (「绿色的界面」, green interface, also means something as a whole), and are recorded separately for pixel filtering
        var leftover = text
        // Color characters that aren't color conditions (「白」 in 「明白」, "understand") stay in the semantic part
        for color in ColorName.allCases where colored(color) {
            for alias in color.aliases where leftover.containsWord(alias) {
                if !q.colors.contains(color) { q.colors.append(color) }
                leftover = leftover.removingWord(alias)
            }
        }
        if let color = judged?.color, !q.colors.contains(color) { q.colors.append(color) }
        if let c = filters.color, !q.colors.contains(c) { q.colors.append(c) }
        q.visual = judged?.visual ?? false

        // When only color words and connectives are left (「和」 in 「视频和文档」, videos and documents), skip semantics and filter by color and type only
        let semantic = tokenize(leftover).isEmpty ? "" : tidy(text)
        q.semantic = semantic
        q.tokens = tokenize(semantic)
        return q
    }

    /// Recognize intent without a model. Drawing a card and asking for inspiration only match when the whole sentence is the command (「抽一张」, 「给我点灵感」): if the sentence has other words,
    /// it's most likely something to find (「灵感板参考」, inspiration board references), treated as finding cards. Questions only match when stated very plainly; no words are removed, and the cards it's based on still gather
    static func intent(of text: String) -> Intent {
        let text = text.lowercased()
        for (intent, commands, _) in hints where commands.contains(where: text.contains) {
            if tokenize(removingHints(of: intent, from: text)).isEmpty { return intent }
        }
        if questions.contains(where: text.contains) || text.hasSuffix("?") || text.hasSuffix("？") || text.hasSuffix("吗") { return .ask }
        return .find
    }

    /// Remove this intent's command words; what's left is the topic. Finding cards and questions have no command words and are returned as is
    static func removingHints(of intent: Intent, from text: String) -> String {
        guard let hint = hints.first(where: { $0.intent == intent }) else { return text }
        return (hint.commands + hint.companions).reduce(text) { $0.replacingOccurrences(of: $1, with: " ", options: .caseInsensitive) }
    }

    /// Ways to phrase the command. commands on their own are a command; companions are words that often follow a command (「抽一张塔罗牌」, draw a tarot card),
    /// and on their own are what's being searched for. Longer ones come first and are removed first
    private static let hints: [(intent: Intent, commands: [String], companions: [String])] = [
        (.draw, ["帮我抽一张", "抽一张", "抽张", "抽一下", "抽卡", "随便来一张", "随机一张", "draw a card", "pick a card", "random card"],
         ["塔罗牌", "塔罗", "tarot"]),
        (.inspire, ["给我点灵感", "给点灵感", "来点灵感", "找点灵感", "give me some inspiration", "give me inspiration", "inspire me"],
         ["灵感", "inspire", "inspiration"]),
    ]
    private static let questions = ["都在讲什么", "讲了什么", "说了什么", "是什么意思", "为什么", "有什么区别", "总结一下",
                                    "what is", "what are", "what's", "why", "difference between", "summarize", "sum up"]

    static let timePhrases: [(String, Int)] = [
        ("今天", 1), ("昨天", 2), ("这几天", 5), ("前几天", 7), ("本周", 7), ("这周", 7), ("这个星期", 7),
        ("上周", 14), ("上个星期", 14), ("本月", 31), ("这个月", 31), ("最近一个月", 31), ("上个月", 62), ("最近", 14), ("近期", 14),
        ("today", 1), ("yesterday", 2), ("these days", 5), ("this week", 7), ("last week", 14), ("this month", 31), ("last month", 62),
        ("recently", 14), ("recent", 14), ("lately", 14),
    ]
    /// Type words. To users, 「文章」 (article) and 「笔记」 (note) don't distinguish web pages, documents, or long text they wrote themselves, so they match several types at once
    static let kindWords: [(String, Set<Kind>)] = [
        ("引文", [.text]), ("语录", [.text]), ("名言", [.text]), ("句子", [.text]), ("文字", [.text]), ("quote", [.text]),
        ("文章", [.web, .document, .text]), ("笔记", [.web, .document, .text, .image]),
        ("链接", [.web]), ("网页", [.web]), ("link", [.web]),
        ("图片", [.image]), ("照片", [.image]), ("图像", [.image]), ("截图", [.image]), ("image", [.image]), ("photo", [.image]),
        ("文档", [.document]), ("pdf", [.document]), ("document", [.document]),
        ("视频", [.video]), ("影片", [.video]), ("video", [.video]),
        ("音频", [.audio]), ("录音", [.audio]), ("播客", [.audio]), ("audio", [.audio]),
    ]
    /// Words that only connect, which would dilute the meaning in an embedding
    static let fillers = ["收集的", "收藏的", "收过的", "收的", "存的", "相关的", "相关", "内容", "的东西", "资料", "一些", "有关"]

    static func tidy(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).replacingOccurrences(of: "  ", with: " ")
    }

    private static let stopwords: Set<String> = ["的", "了", "和", "与", "及", "或", "跟", "还有", "以及", "a", "an", "the", "of", "and", "or"]

    /// Chinese is split into words (「哲学」, 「界面」), English by word; words that only connect are removed
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
    /// How the sentence says this color
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
    /// Chinese matches by substring; English needs whole-word matches, so the red in inspired isn't taken as red
    func containsWord(_ word: String) -> Bool {
        guard word.allSatisfy(\.isASCII) else { return contains(word) }
        return range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }

    func removingWord(_ word: String) -> String {
        guard word.allSatisfy(\.isASCII) else { return replacingOccurrences(of: word, with: " ") }
        return replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", with: " ", options: .regularExpression)
    }
}
