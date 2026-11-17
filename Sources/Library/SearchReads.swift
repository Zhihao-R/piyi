import Foundation
import GRDB

/// A card as search and inspiration need to read it: search text, colors, vector, which boards it's on. Scoring rules live in the intelligence module
public struct SearchRow: Sendable {
    public var card: Card
    /// The vector's raw bytes and model name; nil if not computed yet
    public var vector: Data?
    public var model: String?
    public var boards: Set<Int64>
}

/// How a card is placed on another board: gathering keeps its crop and proportions from it and shows where it came from
public struct Home: Sendable, Equatable {
    public var placement: Placement
    public var boardName: String
}

extension Store {
    /// All non-deleted, fully extracted cards (content still being extracted hasn't arrived, so it can't be found or say anything)
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

    /// Card appearances by ID, in the order of the IDs passed in
    public func faces(_ ids: [Int64]) async throws -> [CardFace] {
        guard !ids.isEmpty else { return [] }
        let faces = try await db.read { db in
            try CardFace.fetchAll(db, sql: "SELECT \(CardFace.columns) FROM liveCard c WHERE c.id IN (\(ids.map(String.init).joined(separator: ",")))")
        }
        let byID = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// How these cards are placed on other boards, taken from the most recently opened board; cards on no board are left out
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
