import Foundation
import GRDB

extension Store {
    // MARK: Sorting reads and writes. Which card goes on which board is decided by the intelligence module; this only reads and writes

    /// Which board entries sit directly on each board. For which cards a board has, see searchRows' boards
    public func boardEntries() async throws -> [Int64: Set<Int64>] {
        try await db.read { db in
            var entries: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT boardID, entryBoardID FROM placement WHERE entryBoardID IS NOT NULL") {
                entries[row[0], default: []].insert(row[1])
            }
            return entries
        }
    }

    /// Cards waiting to be sorted: not sorted yet, extracted, not partial, body completion finished. Whether understanding is done is judged by the intelligence module from the basis
    public func unsortedCards() async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE sorted = 0 AND extraction = ? AND partial IS NULL AND bodyCompleted = 1",
                              arguments: [Extraction.complete])
        }
    }

    /// Write one card's sorting result at once. Recheck each item before writing: the card isn't trashed, isn't on this board yet (you may have just placed it by hand), the board still exists and auto-sort is still on;
    /// skip ones that fail, put the rest on top with the newly-placed mark. Finally mark the card sorted. Returns the placements written (for undo)
    public func recordSorting(_ card: Int64, placements: [Placement]) async throws -> [Placement] {
        try await db.write { db in
            guard let trashed = try Bool.fetchOne(db, sql: "SELECT trashedAt IS NOT NULL FROM card WHERE id = ?", arguments: [card]) else { return [] }
            var written: [Placement] = []
            for var p in placements where !trashed {
                guard try Board.filter(key: p.boardID).filter(Column("autoSort") == true).fetchCount(db) > 0,
                      try Placement.filter(Column("boardID") == p.boardID && Column("cardID") == card).isEmpty(db) else { continue }
                p.id = nil
                p.cardID = card
                p.unseen = true
                p.z = try Self.topZ(db, p.boardID) + 1
                try p.insert(db)
                written.append(p)
            }
            try db.execute(sql: "UPDATE card SET sorted = 1 WHERE id = ?", arguments: [card])
            return written
        }
    }

    /// Clear a board's newly-placed marks when leaving it
    public func clearUnseen(on board: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE placement SET unseen = 0 WHERE boardID = ? AND unseen = 1", arguments: [board]) }
    }

    /// "Sort These Cards": mark cards in "Unsorted" as not sorted again, returning how many
    public func resortUnplaced() async throws -> Int {
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET sorted = 0 WHERE id IN (SELECT c.id FROM liveCard c WHERE \(Self.unplaced))")
            return db.changesCount
        }
    }

    /// Mark the cards on a board as sorted (the sample cards from a fresh install, so they don't get sorted into your boards)
    public func markSorted(on board: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET sorted = 1 WHERE id IN (SELECT cardID FROM placement WHERE boardID = ?)", arguments: [board]) }
    }

    /// Body completion finished
    public func markBodyCompleted(_ id: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET bodyCompleted = 1 WHERE id = ?", arguments: [id]) }
    }

    /// Cards extracted but with body completion unfinished: left undone at last quit, continued this time. Partial cards don't count; they're completed when refetched in full
    public func bodiesToComplete() async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE extraction = ? AND partial IS NULL AND bodyCompleted = 0", arguments: [Extraction.complete])
        }
    }

    /// Change a board's sorting settings. The rule is trimmed of surrounding whitespace; empty counts as not written
    public func setSorting(_ board: Int64, autoSort: Bool, rule: String?) async throws {
        let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await db.write { db in
            _ = try Board.filter(key: board).updateAll(db, Column("autoSort").set(to: autoSort), Column("rule").set(to: rule?.isEmpty == false ? rule : nil))
        }
    }
}
