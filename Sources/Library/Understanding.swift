import Foundation
import GRDB

/// Understanding results written by the generation capability, written back as a whole set
public struct Generated: Sendable {
    public var title: String
    public var caption: String
    public var detail: String?
    public var tags: [String]
    /// Short content has no summary
    public var summary: String?
    /// Which passage of the original each key point is based on, matching the lines starting with "· " in summary one to one; nil for a point with no basis it can name
    public var anchors: [SummaryAnchor?]?

    public init(title: String, caption: String, detail: String?, tags: [String], summary: String?, anchors: [SummaryAnchor?]? = nil) {
        (self.title, self.caption, self.detail, self.tags, self.summary, self.anchors) = (title, caption, detail, tags, summary, anchors)
    }
}

/// The passage a key point is based on. Like citations in discussions, it stores the words, not the number: numbers change after a refetch, the words can still find the passage (Passages.find)
public struct SummaryAnchor: Codable, Sendable, Equatable {
    public var part: Passage.Part
    public var quote: String

    public init(part: Passage.Part, quote: String) { (self.part, self.quote) = (part, quote) }
}

extension Card {
    public mutating func apply(_ g: Generated) {
        (generatedTitle, caption, detail, tags, summary, summaryAnchors) = (g.title, g.caption, g.detail, g.tags, g.summary, g.anchors)
    }
}

/// Card counts across the library, shown in the status bar
public struct Counts: Sendable, Equatable {
    public var board: Int?
    public var library = 0
    /// Being extracted or queued for understanding
    public var processing = 0
    public var waitingKey = 0
    public var failed = 0

    public init() {}
}

extension Store {
    // MARK: Understanding queue reads and writes. Queuing rules live in the intelligence module; this only reads and writes

    /// Non-deleted cards whose content has been extracted; understanding picks its work from here
    public func extractedCards() async throws -> [Card] {
        try await db.read { db in try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE extraction = ?", arguments: [Extraction.complete]) }
    }

    /// Which model and which text each card's vector was computed from
    public func vectorBases() async throws -> [Int64: (model: String, basis: String)] {
        try await db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT cardID, model, basis FROM vector").map { ($0[0] as Int64, ($0[1] as String, $0[2] as String)) })
        }
    }

    /// Change the understanding state of a batch of cards; only writes the ones that changed
    public func setUnderstanding(_ state: Understanding?, for cards: [Int64]) async throws {
        guard !cards.isEmpty else { return }
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET understanding = ? WHERE id IN (\(cards.map(String.init).joined(separator: ","))) AND understanding IS NOT ?",
                           arguments: [state, state])
        }
    }

    /// Write back understanding results: the generated set is written with its basis recorded, clearing the last failure reason; colors are written separately.
    /// basis is the card content's basis when understanding started: if the card was refetched and its content changed meanwhile, this result is void and it returns false
    @discardableResult
    public func saveUnderstanding(_ id: Int64, basis: String, generated: Generated?, colors: String?) async throws -> Bool {
        try await db.write { db in
            guard var card = try Card.fetchOne(db, key: id), card.contentBasis == basis else { return false }
            if let generated {
                card.apply(generated)
                card.understoodBasis = basis
                card.understandError = nil
                // Only vectors remain: written together with the new title, so the badge and title on the canvas change together, not in two steps
                card.understanding = .indexing
            }
            if let colors { card.colors = colors }
            try card.update(db)
            return true
        }
    }

    public func saveVector(_ vector: Vector) async throws {
        try await db.write { db in
            guard try Card.exists(db, key: vector.cardID) else { return }
            try vector.save(db)
        }
    }

    /// Understanding failed: record the reason, no automatic retry, wait for you to click Retry or for the content to change
    public func failUnderstanding(_ id: Int64, _ reason: String) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET understandError = ?, understanding = NULL WHERE id = ?", arguments: [reason, id])
        }
    }

    /// Retry failed understanding
    public func retryFailedUnderstanding() async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET understandError = NULL WHERE understandError IS NOT NULL") }
    }

    /// Right-click "Read Again": clear the basis, failure reason and vectors, recompute everything next round
    public func forgetUnderstanding(_ cards: [Int64]) async throws {
        try await db.write { db in
            try Card.filter(keys: cards).updateAll(db, Column("understoodBasis").set(to: nil), Column("understandError").set(to: nil), Column("colors").set(to: nil))
            try Vector.filter(cards.contains(Column("cardID"))).deleteAll(db)
        }
    }

    // MARK: Counts

    public func counts(board: Int64?) async throws -> Counts {
        try await db.read { db in
            var c = Counts()
            if let board {
                c.board = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT p.cardID) FROM placement p JOIN liveCard c ON c.id = p.cardID WHERE p.boardID = ?", arguments: [board])
            }
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*),
                       SUM(extraction = ? OR understanding IN (?, ?)),
                       SUM(understanding = ?),
                       SUM(understandError IS NOT NULL)
                FROM liveCard
                """, arguments: [Extraction.extracting, Understanding.generating, Understanding.indexing, Understanding.waitingKey])!
            c.library = row[0] ?? 0
            c.processing = row[1] ?? 0
            c.waitingKey = row[2] ?? 0
            c.failed = row[3] ?? 0
            return c
        }
    }

    // MARK: Settings

    public func setting<T: Codable & Sendable>(_ key: String, as type: T.Type) async throws -> T? {
        try await db.read { db in
            try Setting.fetchOne(db, key: key).flatMap { try JSONDecoder().decode(T.self, from: Data($0.value.utf8)) }
        }
    }

    public func setSetting<T: Codable & Sendable>(_ key: String, _ value: T) async throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await db.write { db in try Setting(key: key, value: json).save(db) }
    }
}
