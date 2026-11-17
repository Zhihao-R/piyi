import Foundation
import Library

/// What search needs to look at a card: text for literal matching, colors, embedding, which boards it's on
public struct SearchCard: Sendable {
    public var id: Int64
    public var kind: Kind
    public var collectedAt: Date
    /// Lowercased search text: title, description, long description for search, tags, format, all body text and subtitles, source
    public var text: String
    /// Share of the image each color takes; text cards have no pixels, so nil
    public var colors: [ColorName: Float]?
    public var vector: [Float]?
    public var boards: Set<Int64>
    /// One line for the model: type, title, description, detailed description, tags
    public var brief: String
    /// Cover file: a small image is attached for the model when it needs to see the image
    public var cover: String?

    public init(id: Int64, kind: Kind, collectedAt: Date, text: String, colors: [ColorName: Float]?, vector: [Float]?,
                boards: Set<Int64> = [], brief: String = "", cover: String? = nil) {
        (self.id, self.kind, self.collectedAt, self.text, self.colors, self.vector) = (id, kind, collectedAt, text, colors, vector)
        (self.boards, self.brief, self.cover) = (boards, brief, cover)
    }
}

/// Rough search: embedding and literal scores together. The thresholds are tuned for the local embeddings
public enum Ranking {
    /// At most how many to show
    public static let maxResults = 24
    /// Cutoff: no lower than floor, and no lower than relative times the top score. A very specific query keeps only the truly relevant few; a broad one gets more
    public struct Cutoff: Sendable {
        public var floor: Double, relative: Double
        public static let standard = Cutoff(floor: 1.2, relative: 0.45)
    }

    /// Cards with a literal hit (lit up in place while typing): at least half the query words hit, and the type, time and color conditions are met
    public static func literal(_ cards: [SearchCard], _ q: Query, now: Date = .now) -> [Int64] {
        guard !q.tokens.isEmpty else { return [] }
        return eligible(cards, q, now: now).filter { lexical($0, q) >= 0.5 && colorOK($0, q) }.map(\.id)
    }

    /// A candidate and its score. pinned: cards with no embedding yet but every query word hit literally can't be scored by meaning, so they're included regardless of the threshold
    public typealias Scored = (id: Int64, score: Double, pinned: Bool)

    /// All candidates with scores, sorted (not truncated); semantic is the embedding of the query's semantic part; without it only literal and color are used
    public static func scored(_ cards: [SearchCard], _ q: Query, semantic vector: [Float]?, now: Date = .now) -> [Scored] {
        guard !q.isEmpty else { return [] }
        let pool = eligible(cards, q, now: now)

        // Similarity is converted to "how many standard deviations above the library average". Mean and standard deviation are computed over the whole library, so the cutoff is the same for one sentence with or without a type filter
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
        // Only time and type conditions: newest collected first
        return pool.sorted { $0.collectedAt > $1.collectedAt }.enumerated().map { ($0.element.id, -Double($0.offset), false) }
    }

    /// What to show: with embeddings, cut by threshold (pinned ones ignore it: a card just collected can be found by remembering its exact words); without embeddings, cut by count
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

    /// Text cards have no pixels; a color condition just adds no points for them, it doesn't exclude them
    static func colorOK(_ card: SearchCard, _ q: Query) -> Bool {
        q.colors.isEmpty || card.colors == nil || colorScore(card, q) >= 0.06
    }
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0
    for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
    return s
}
