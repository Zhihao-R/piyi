import Foundation
import CoreGraphics
import GRDB

/// One entry the canvas gets when reading a board: the placement + what it needs to draw this card
public struct BoardItem: Sendable, Identifiable, Equatable {
    public var id: Int64 { placement.id! }
    public var placement: Placement
    public var face: Face
    /// Temporary zoom while gathered (not saved to the library): text cards scale their font with it, so it looks like the whole card held up close
    public var zoom: Double = 1

    public init(placement: Placement, face: Face) {
        self.placement = placement
        self.face = face
    }
}

public enum Face: Sendable, Equatable {
    case card(CardFace)
    case entry(board: Int64, name: String, collage: String?)
}

/// What drawing a card needs. Only the opening part of the body, so reading thousands of cards at once doesn't haul whole articles
public struct CardFace: Sendable, Equatable, FetchableRecord, Decodable {
    /// Text cards show more words when enlarged. At twice the default width (about 480×800), minus the cover and key points, roughly 1000 characters fit; bigger than that and it's time for the detail view
    public static let excerptLength = 1000

    public var id: Int64
    public var kind: Kind
    public var form: Form?
    public var cover: String?
    /// The original file (animated images play it on hover)
    public var original: String?
    public var title: String
    /// Text you wrote yourself or the extracted body, the opening part
    public var excerpt: String
    /// excerpt is text you wrote yourself (a quote, a quick note), not an extracted body
    public var isOwnText: Bool
    /// Key points of a long piece, one per line
    public var summary: String?
    /// Total length in characters
    public var length: Int
    public var source: String?
    public var format: String?
    public var url: String?
    public var pages: Int?
    public var duration: Double?
    /// Total number of images (the cover plus the rest)
    public var images: Int
    public var extraction: Extraction
    public var partial: Partial?
    public var understanding: Understanding?
    /// Background color name of a text card you wrote
    public var tint: String?
    /// When it was collected: the library groups by day with it
    public var collectedAt: Date
    /// Color statistics (computed from pixels during understanding, JSON): the library groups by color with it
    public var colors: String?

    /// The URL's site name, without www.
    public var site: String? {
        guard let host = url.flatMap(URL.init(string:))?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Query columns for reading a card's appearance; c is an alias for liveCard or card
    static let columns = """
        c.id, c.kind, c.form, c.cover, c.original, c.extraction, c.partial, c.understanding, c.source, c.format, c.pages, c.duration, c.tint, c.collectedAt, c.colors,
        COALESCE(c.url, c.sourceURL) AS url,
        -- Same display-title rule as Card.displayTitle; change both together
        CASE WHEN c.kind IN ('image', 'text') THEN COALESCE(c.generatedTitle, c.title, '') ELSE COALESCE(c.title, c.generatedTitle, '') END AS title,
        -- Strip image markers, same as Article.plain
        replace(replace(substr(COALESCE(c.text, c.body, c.caption, ''), 1, \(excerptLength)), char(65532) || char(10), ''), char(65532), '') AS excerpt,
        c.summary,
        c.text IS NOT NULL AS isOwnText,
        length(COALESCE(c.text, c.body, '')) AS length,
        (c.cover IS NOT NULL) + (SELECT COUNT(*) FROM cardImage i WHERE i.cardID = c.id) AS images
        """
}

extension Store {
    // MARK: Boards

    /// Most recently opened first
    public func boards() async throws -> [Board] {
        try await db.read { db in try Board.order(Column("openedAt").desc).fetchAll(db) }
    }

    public func createBoard(_ name: String) async throws -> Board {
        try await db.write { db in
            var board = Board(name: name)
            try board.insert(db)
            return board
        }
    }

    public func renameBoard(_ id: Int64, to name: String) async throws {
        try await db.write { db in _ = try Board.filter(key: id).updateAll(db, Column("name").set(to: name)) }
    }

    /// Swap in a new thumbnail collage; delete the old one if nothing else uses it
    public func setCollage(_ id: Int64, jpeg: Data) async throws {
        let name = try files.put(jpeg, ext: "jpg")
        for tier in FileStore.tiers { files.makeThumbnail(of: name, tier: tier, long: false) }
        let old = try await db.write { db -> String? in
            let old = try String.fetchOne(db, sql: "SELECT collage FROM board WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE board SET collage = ? WHERE id = ?", arguments: [name, id])
            return old == name || old == nil ? nil : try Self.isReferenced(db, old!) ? nil : old
        }
        if let old { files.remove(old) }
    }

    public func markOpened(_ id: Int64) async throws {
        try await db.write { db in _ = try Board.filter(key: id).updateAll(db, Column("openedAt").set(to: Date.now)) }
    }

    /// Cards on the board that aren't on any other board (used for the prompt before deleting a board)
    public func cardsOnlyOn(_ board: Int64) async throws -> [Int64] {
        try await db.read { db in try Self.cardsOnlyOn(db, board) }
    }

    static func cardsOnlyOn(_ db: Database, _ board: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT DISTINCT p.cardID FROM placement p JOIN liveCard c ON c.id = p.cardID
            WHERE p.boardID = ?1
              AND NOT EXISTS (SELECT 1 FROM placement q WHERE q.cardID = p.cardID AND q.boardID != ?1)
            """, arguments: [board])
    }

    /// Deleting a board really deletes it. Cards only on it are kept or trashed as chosen; entries to it on other boards are removed with it
    public func deleteBoard(_ id: Int64, trashingOrphans: Bool) async throws {
        try await db.write { db in
            if trashingOrphans { try Self.setTrashed(db, try Self.cardsOnlyOn(db, id), at: .now) }
            _ = try Board.deleteOne(db, key: id)
        }
    }

    // MARK: Placement

    /// Put a card on a board, on top of the stack
    @discardableResult
    public func place(card: Int64, on board: Int64, frame: CGRect) async throws -> Placement {
        try await db.write { db in try Self.place(db, card: card, on: board, frame: frame) }
    }

    /// Write a batch of placements into boards at once, on top, keeping their relative order. The newly-placed mark doesn't follow the card to another board. Returns what was written
    @discardableResult
    public func place(_ placements: [Placement]) async throws -> [Placement] {
        try await db.write { db in
            var top = [Int64: Double]()
            return try placements.map { p in
                var p = p
                let z = try top[p.boardID] ?? Self.topZ(db, p.boardID)
                p.id = nil
                p.unseen = false
                p.z = z + 1
                top[p.boardID] = z + 1
                try p.insert(db)
                return p
            }
        }
    }

    static func place(_ db: Database, card: Int64, on board: Int64, frame: CGRect) throws -> Placement {
        var p = Placement(boardID: board, cardID: card, frame: frame, z: try topZ(db, board) + 1)
        try p.insert(db)
        return p
    }

    /// Put an entry to board child on board parent. Nesting can't form a cycle
    @discardableResult
    public func placeEntry(_ child: Int64, on parent: Int64, frame: CGRect) async throws -> Placement {
        try await db.write { db in
            guard try !Self.reaches(db, from: child, to: parent) else { throw Failure.cycle }
            var p = Placement(boardID: parent, entryBoardID: child, frame: frame, z: try Self.topZ(db, parent) + 1)
            try p.insert(db)
            return p
        }
    }

    /// Follow entries on board from down level by level until board to is found (including when from is to)
    static func reaches(_ db: Database, from: Int64, to: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            WITH RECURSIVE reach(id) AS (
                SELECT ?1
                UNION SELECT p.entryBoardID FROM placement p JOIN reach ON p.boardID = reach.id WHERE p.entryBoardID IS NOT NULL
            )
            SELECT EXISTS(SELECT 1 FROM reach WHERE id = ?2)
            """, arguments: [from, to]) ?? false
    }

    /// Change a placement's position, size, angle, mirroring, stacking order, crop (drag, tidy, resize, rotate, crop): write only these columns, in a single write.
    /// The newly-placed mark isn't written: the canvas's copy may be stale. If a placement was already taken away elsewhere by the time of writing (e.g. sorting was undone), skip it
    public func update(_ placements: [Placement]) async throws {
        try await db.write { db in
            for p in placements {
                do { try p.update(db, columns: ["x", "y", "width", "height", "rotation", "flipX", "flipY", "z", "crop"]) } catch RecordError.recordNotFound {}
            }
        }
    }

    /// Take off this board: only deletes placements; the cards stay in the library. Returns the deleted placements so undo can put them back as they were
    @discardableResult
    public func removePlacements(_ ids: [Int64]) async throws -> [Placement] {
        try await db.write { db in
            let removed = try Placement.fetchAll(db, keys: ids)
            _ = try Placement.deleteAll(db, keys: ids)
            return removed
        }
    }

    /// Undo/redo adding and removing placements: take away removing, put adding back as-is with their original IDs.
    /// IDs are never taken by new placements (autoincrement doesn't reuse), so earlier steps in the undo history still recognize them.
    /// Skip what can't go back: the board was deleted (another board's undo history still points to it), or putting an entry back would form a cycle (after taking it away, an entry was placed the other way round)
    public func exchangePlacements(adding: [Placement], removing: [Int64]) async throws {
        try await db.write { db in
            _ = try Placement.deleteAll(db, keys: removing)
            for var p in adding {
                let boards = [p.boardID] + [p.entryBoardID].compactMap { $0 }
                guard try Board.filter(keys: boards).fetchCount(db) == boards.count else { continue }
                if let child = p.entryBoardID, try Self.reaches(db, from: child, to: p.boardID) { continue }
                try p.insert(db)
            }
        }
    }

    /// The condition for "Unsorted"; c is an alias for the card table
    static let unplaced = "NOT EXISTS (SELECT 1 FROM placement q WHERE q.cardID = c.id)"

    static func topZ(_ db: Database, _ board: Int64) throws -> Double {
        try Double.fetchOne(db, sql: "SELECT MAX(z) FROM placement WHERE boardID = ?", arguments: [board]) ?? 0
    }

    // MARK: Canvas reads

    /// Card views that don't belong to a board
    public enum Collection: Sendable, Hashable {
        case all, unplaced, trash
    }

    /// Cards in the view and the size they had on a board (nil if never placed; the canvas sizes it by content). Newest first: by collection time, or by the time of the latest re-collect
    public func cards(in collection: Collection) async throws -> [(face: CardFace, size: CGSize?)] {
        // Everything except the trash reads from the non-deleted card table
        let source = switch collection {
        case .all: "liveCard c"
        case .unplaced: "liveCard c WHERE \(Self.unplaced)"
        case .trash: "card c WHERE c.trashedAt IS NOT NULL"
        }
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(CardFace.columns),
                       (SELECT width FROM placement q WHERE q.cardID = c.id LIMIT 1) AS placedWidth,
                       (SELECT height FROM placement q WHERE q.cardID = c.id LIMIT 1) AS placedHeight
                FROM \(source) ORDER BY COALESCE(c.resurfacedAt, c.collectedAt) DESC
                """)
            return try rows.map { row in
                let size = (row["placedWidth"] as Double?).map { CGSize(width: $0, height: row["placedHeight"] as Double? ?? $0) }
                return (try CardFace(row: row), size)
            }
        }
    }

    /// All placements on a board, in stacking order; cards in the trash don't appear
    public func items(on board: Int64) async throws -> [BoardItem] {
        try await db.read { db in
            let placements = try Placement.filter(Column("boardID") == board).order(Column("z")).fetchAll(db)
            let faces = try CardFace.fetchAll(db, sql: """
                SELECT DISTINCT \(CardFace.columns) FROM liveCard c JOIN placement p ON p.cardID = c.id WHERE p.boardID = ?
                """, arguments: [board])
            let byCard = Dictionary(faces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let entries = try Board.filter(keys: placements.compactMap(\.entryBoardID)).fetchAll(db)
            let byBoard = Dictionary(uniqueKeysWithValues: entries.map { ($0.id!, $0) })
            return placements.compactMap { p in
                if let id = p.cardID, let face = byCard[id] { return BoardItem(placement: p, face: .card(face)) }
                if let id = p.entryBoardID, let b = byBoard[id] { return BoardItem(placement: p, face: .entry(board: id, name: b.name, collage: b.collage)) }
                return nil
            }
        }
    }
}
