import Foundation
import GRDB

/// 搜索、灵感要读的一张卡：检索文字、颜色、向量、在哪些画板里。打分规则在智能块
public struct SearchRow: Sendable {
    public var card: Card
    /// 向量的原始字节和模型名；还没算的为 nil
    public var vector: Data?
    public var model: String?
    public var boards: Set<Int64>
}

/// 一张卡在别的画板里的摆法：聚拢时按它保留裁剪和比例，并标出出处
public struct Home: Sendable, Equatable {
    public var placement: Placement
    public var boardName: String
}

extension Store {
    /// 全部未删除、已抽完的卡（正在抽取的内容没到，搜不到也说不出什么）
    public func searchRows() async throws -> [SearchRow] {
        try await db.read { db in
            let cards = try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE extraction = ?", arguments: [Extraction.complete])
            var vectors: [Int64: (Data, String)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT cardID, data, model FROM vector") { vectors[row[0]] = (row[1], row[2]) }
            var boards: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT cardID, boardID FROM placement WHERE cardID IS NOT NULL") {
                boards[row[0], default: []].insert(row[1])
            }
            return cards.map { SearchRow(card: $0, vector: vectors[$0.id!]?.0, model: vectors[$0.id!]?.1, boards: boards[$0.id!] ?? []) }
        }
    }

    /// 按编号取卡片外观，顺序跟着传进来的编号
    public func faces(_ ids: [Int64]) async throws -> [CardFace] {
        guard !ids.isEmpty else { return [] }
        let faces = try await db.read { db in
            try CardFace.fetchAll(db, sql: "SELECT \(CardFace.columns) FROM liveCard c WHERE c.id IN (\(ids.map(String.init).joined(separator: ",")))")
        }
        let byID = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// 这些卡在别的画板里的摆法，取最近打开的那个画板；哪个画板都没放的不在结果里
    public func homes(of cards: [Int64], excluding board: Int64?) async throws -> [Int64: Home] {
        guard !cards.isEmpty else { return [:] }
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.*, b.name AS boardName FROM placement p JOIN board b ON b.id = p.boardID
                WHERE p.cardID IN (\(cards.map(String.init).joined(separator: ","))) AND p.boardID IS NOT ?
                ORDER BY b.openedAt DESC
                """, arguments: [board])
            var homes: [Int64: Home] = [:]
            for row in rows {
                let p = try Placement(row: row)
                if homes[p.cardID!] == nil { homes[p.cardID!] = Home(placement: p, boardName: row["boardName"]) }
            }
            return homes
        }
    }
}
