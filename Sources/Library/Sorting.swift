import Foundation
import GRDB

extension Store {
    // MARK: 分拣读写。哪张卡放进哪个画板由智能块判断，这里只管读和写

    /// 每个画板里直接摆着哪些画板的入口。画板里有哪些卡看 searchRows 的 boards
    public func boardEntries() async throws -> [Int64: Set<Int64>] {
        try await db.read { db in
            var entries: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT boardID, entryBoardID FROM placement WHERE entryBoardID IS NOT NULL") {
                entries[row[0], default: []].insert(row[1])
            }
            return entries
        }
    }

    /// 等着分拣的卡：没分拣过、抽取完、不是残缺卡、补全正文结束。理解做没做完由智能块按依据判断
    public func unsortedCards() async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE sorted = 0 AND extraction = ? AND partial IS NULL AND bodyCompleted = 1",
                              arguments: [Extraction.complete])
        }
    }

    /// 一次写入一张卡的分拣结果。写之前逐项重新检查：卡没进废纸篓，还不在这个画板里（你可能刚手动放过），画板还在、自动分拣还开着；
    /// 不满足的跳过，其余带上新放进标记叠在最上面。最后把卡标成已分拣。返回写进去的摆放（撤销用）
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

    /// 离开画板时清掉它的新放进标记
    public func clearUnseen(on board: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE placement SET unseen = 0 WHERE boardID = ? AND unseen = 1", arguments: [board]) }
    }

    /// 「分拣这些卡」：「未归类」里的卡重新标成未分拣，返回几张
    public func resortUnplaced() async throws -> Int {
        try await db.write { db in
            try db.execute(sql: "UPDATE card SET sorted = 0 WHERE id IN (SELECT c.id FROM liveCard c WHERE \(Self.unplaced))")
            return db.changesCount
        }
    }

    /// 画板里的卡都标成已分拣（新装时的示例卡，免得它们自己被分进你的画板）
    public func markSorted(on board: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET sorted = 1 WHERE id IN (SELECT cardID FROM placement WHERE boardID = ?)", arguments: [board]) }
    }

    /// 补全正文结束
    public func markBodyCompleted(_ id: Int64) async throws {
        try await db.write { db in try db.execute(sql: "UPDATE card SET bodyCompleted = 1 WHERE id = ?", arguments: [id]) }
    }

    /// 抽取完了、补全正文还没结束的卡：上次退出时没做完的，这次接着做。残缺卡不算，补抓完整时会补
    public func bodiesToComplete() async throws -> [Card] {
        try await db.read { db in
            try Card.fetchAll(db, sql: "SELECT * FROM liveCard WHERE extraction = ? AND partial IS NULL AND bodyCompleted = 0", arguments: [Extraction.complete])
        }
    }

    /// 改画板的分拣设置。规则去掉首尾空白，空的当没写
    public func setSorting(_ board: Int64, autoSort: Bool, rule: String?) async throws {
        let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await db.write { db in
            _ = try Board.filter(key: board).updateAll(db, Column("autoSort").set(to: autoSort), Column("rule").set(to: rule?.isEmpty == false ? rule : nil))
        }
    }
}
