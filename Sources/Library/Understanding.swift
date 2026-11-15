import Foundation
import GRDB

/// 生成能力写出的理解结果，整组写回
public struct Generated: Sendable {
    public var title: String
    public var caption: String
    public var detail: String?
    public var tags: [String]
    /// 短内容没有总结
    public var summary: String?
    /// 每条要点依据原文的哪一段，和 summary 里「· 」开头的行一一对应；说不出依据的那条为 nil
    public var anchors: [SummaryAnchor?]?

    public init(title: String, caption: String, detail: String?, tags: [String], summary: String?, anchors: [SummaryAnchor?]? = nil) {
        (self.title, self.caption, self.detail, self.tags, self.summary, self.anchors) = (title, caption, detail, tags, summary, anchors)
    }
}

/// 一条要点依据的那一段。和讨论里的引用一样存原话不存编号：重新抓取后编号会变，原话还能找回那一段（Passages.find）
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

/// 资料库里各处的卡片张数，状态栏显示
public struct Counts: Sendable, Equatable {
    public var board: Int?
    public var library = 0
    /// 正在抽取和排队理解的
    public var processing = 0
    public var waitingKey = 0
    public var failed = 0

    public init() {}
}

extension Store {
    // MARK: 理解队列读写。排队规则在智能块，这里只管读和写

    /// 内容已经抽完的未删除卡片，理解从这里挑要做的
    public func extractedCards() async throws -> [Card] {
        try await db.read { db in try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE extraction = ?", arguments: [Extraction.complete]) }
    }

    /// 每张卡的向量是哪个模型、依据哪段文字算的
    public func vectorBases() async throws -> [Int64: (model: String, basis: String)] {
        try await db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT cardID, model, basis FROM vector").map { ($0[0] as Int64, ($0[1] as String, $0[2] as String)) })
        }
    }

    /// 一批卡换理解状态；只写变了的
    public func setUnderstanding(_ state: Understanding?, for cards: [Int64]) async throws {
        guard !cards.isEmpty else { return }
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET understanding = ? WHERE id IN (\(cards.map(String.init).joined(separator: ","))) AND understanding IS NOT ?",
                           arguments: [state, state])
        }
    }

    /// 写回理解结果：生成出来的整组写入并记上依据，清掉上次失败的原因；颜色单独写。
    /// basis 是开始理解时卡片内容的依据：期间卡被重新抓取、内容变了，这次结果作废，返回 false
    @discardableResult
    public func saveUnderstanding(_ id: Int64, basis: String, generated: Generated?, colors: String?) async throws -> Bool {
        try await db.write { db in
            guard var card = try Card.fetchOne(db, key: id), card.contentBasis == basis else { return false }
            if let generated {
                card.apply(generated)
                card.understoodBasis = basis
                card.understandError = nil
                // 剩下只是补向量：和新标题同一次写，画布上角标和标题一起换，不分两次变
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

    /// 理解失败：记下原因，不自动重试，等你点重试或内容变了
    public func failUnderstanding(_ id: Int64, _ reason: String) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET understandError = ?, understanding = NULL WHERE id = ?", arguments: [reason, id])
        }
    }

    /// 重试失败的理解
    public func retryFailedUnderstanding() async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET understandError = NULL WHERE understandError IS NOT NULL") }
    }

    /// 右键「重新理解」：清掉依据、失败原因和向量，下一轮全部重算
    public func forgetUnderstanding(_ cards: [Int64]) async throws {
        try await db.write { db in
            try Card.filter(keys: cards).updateAll(db, Column("understoodBasis").set(to: nil), Column("understandError").set(to: nil), Column("colors").set(to: nil))
            try Vector.filter(cards.contains(Column("cardID"))).deleteAll(db)
        }
    }

    // MARK: 计数

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

    // MARK: 设置

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
