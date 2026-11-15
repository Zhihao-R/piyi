import Foundation
import Library

/// 搜索看一张卡要用到的：字面匹配的文字、颜色、向量、在哪些画板里
public struct SearchCard: Sendable {
    public var id: Int64
    public var kind: Kind
    public var collectedAt: Date
    /// 小写的检索文字：标题、描述、检索用的长描述、标签、格式、全部正文和字幕、出处
    public var text: String
    /// 各种颜色占画面的比例；文字类的卡没有像素，为 nil
    public var colors: [ColorName: Float]?
    public var vector: [Float]?
    public var boards: Set<Int64>
    /// 给模型看的一行：类型、标题、描述、详细描述、标签
    public var brief: String
    /// 封面文件：要看图时给模型附小图
    public var cover: String?

    public init(id: Int64, kind: Kind, collectedAt: Date, text: String, colors: [ColorName: Float]?, vector: [Float]?,
                boards: Set<Int64> = [], brief: String = "", cover: String? = nil) {
        (self.id, self.kind, self.collectedAt, self.text, self.colors, self.vector) = (id, kind, collectedAt, text, colors, vector)
        (self.boards, self.brief, self.cover) = (boards, brief, cover)
    }
}

/// 粗找：向量和字面一起打分。分数线按本机向量调过
public enum Ranking {
    /// 最多展示几张
    public static let maxResults = 24
    /// 入选门槛：不低于 floor，也不低于最高分的 relative 倍。查询很明确时只留真正相关的几张，宽泛时多给一些
    public struct Cutoff: Sendable {
        public var floor: Double, relative: Double
        public static let standard = Cutoff(floor: 1.2, relative: 0.45)
    }

    /// 字面命中的卡（打字时原地亮起）：查询词至少命中一半，并且符合类型、时间、颜色条件
    public static func literal(_ cards: [SearchCard], _ q: Query, now: Date = .now) -> [Int64] {
        guard !q.tokens.isEmpty else { return [] }
        return eligible(cards, q, now: now).filter { lexical($0, q) >= 0.5 && colorOK($0, q) }.map(\.id)
    }

    /// 一张候选和它的分数。pinned：还没算出向量、查询词又字面全中的卡，按意思打不了分，不看分数线直接入选
    public typealias Scored = (id: Int64, score: Double, pinned: Bool)

    /// 排好序的全部候选和分数（不截断）；semantic 是查询语义部分的向量，没有时只用字面和颜色
    public static func scored(_ cards: [SearchCard], _ q: Query, semantic vector: [Float]?, now: Date = .now) -> [Scored] {
        guard !q.isEmpty else { return [] }
        let pool = eligible(cards, q, now: now)

        // 相似度换算成「比全库平均高出几个标准差」。平均值和标准差在全库上算，这样同一句话开不开类型筛选，门槛都一样
        let known = vector.map { v in cards.compactMap { $0.vector.map { Double(dot(v, $0)) } } } ?? []
        if let vector, !q.semantic.isEmpty, !known.isEmpty {
            let mean = known.reduce(0, +) / Double(known.count)
            let std = max(0.01, sqrt(known.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(known.count)))
            return pool.compactMap { card -> Scored? in
                guard colorOK(card, q) else { return nil }
                let z = card.vector.map { (Double(dot(vector, $0)) - mean) / std } ?? -1
                let color = q.colors.isEmpty ? 0 : 2.5 * colorScore(card, q) - 0.3
                let l = lexical(card, q)
                return (card.id, z + 0.6 * l + color, card.vector == nil && l == 1)
            }.sorted { $0.score > $1.score }
        }
        if !q.tokens.isEmpty {
            return pool.compactMap { card -> Scored? in
                let l = lexical(card, q)
                return l > 0 && colorOK(card, q) ? (card.id, l + 1.5 * colorScore(card, q), false) : nil
            }.sorted { $0.score > $1.score }
        }
        if !q.colors.isEmpty {
            return pool.map { ($0.id, colorScore($0, q), false) }.filter { $0.1 >= 0.12 }.sorted { $0.1 > $1.1 }
        }
        // 只有时间、类型条件：按收集时间从新到旧
        return pool.sorted { $0.collectedAt > $1.collectedAt }.enumerated().map { ($0.element.id, -Double($0.offset), false) }
    }

    /// 展示哪些：有向量时按分数线截（pinned 的不看线：刚收的卡记得原话就找得回来），没有向量时按条数截
    public static func shown(_ scored: [Scored], semantic: Bool, cutoff c: Cutoff = .standard) -> [Int64] {
        guard semantic else { return scored.prefix(maxResults).map(\.id) }
        let cutoff = max(c.floor, (scored.first?.score ?? 0) * c.relative)
        let strong = scored.filter { $0.score >= cutoff || $0.pinned }
        return (strong.isEmpty ? Array(scored.prefix(3)) : strong).prefix(maxResults).map(\.id)
    }

    static func eligible(_ cards: [SearchCard], _ q: Query, now: Date) -> [SearchCard] {
        let since = q.since(now)
        return cards.filter { card in
            (q.kinds.isEmpty || q.kinds.contains(card.kind)) && (since.map { card.collectedAt >= $0 } ?? true)
                && { if case .board(let b) = q.scope { card.boards.contains(b) } else { true } }()
        }
    }

    static func lexical(_ card: SearchCard, _ q: Query) -> Double {
        guard !q.tokens.isEmpty else { return 0 }
        return Double(q.tokens.filter { card.text.contains($0) }.count) / Double(q.tokens.count)
    }

    static func colorScore(_ card: SearchCard, _ q: Query) -> Double {
        q.colors.map { Double(card.colors?[$0] ?? 0) }.max() ?? 0
    }

    /// 文字卡没有像素，颜色条件对它只是不加分，不排除
    static func colorOK(_ card: SearchCard, _ q: Query) -> Bool {
        q.colors.isEmpty || card.colors == nil || colorScore(card, q) >= 0.06
    }
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0
    for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
    return s
}
