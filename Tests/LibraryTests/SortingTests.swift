import Testing
import Foundation
import CoreGraphics
import GRDB
@testable import Library

/// Writing sorting results
@Suite struct SortingWrites {
    let store: Store
    let card: Int64

    init() async throws {
        store = try temporaryStore()
        var m = Material(kind: .text)
        m.text = "莫兰迪的配色"
        card = try await store.placeholder(.text, on: nil, frame: .zero)
        _ = try await store.fill(card, with: m)
    }

    func placements(_ boards: [Int64]) -> [Placement] {
        boards.map { Placement(boardID: $0, frame: CGRect(x: 10, y: 20, width: 200, height: 100), z: 0) }
    }

    /// Each item is rechecked before writing: card already on this board, or board just had auto-sorting turned off, these two are skipped, the rest are written as usual, and the card is marked sorted
    @Test func skipsBoardsThatNoLongerQualify() async throws {
        let open = try await store.createBoard("配色").id!, present = try await store.createBoard("字体").id!, closed = try await store.createBoard("排版").id!
        try await store.place(card: card, on: present, frame: .zero)
        try await store.setSorting(closed, autoSort: false, rule: nil)
        let written = try await store.recordSorting(card, placements: placements([open, present, closed]))
        #expect(written.map(\.boardID) == [open])
        #expect(written[0].unseen && written[0].cardID == card)
        #expect(try await store.items(on: present).count == 1)
        #expect(try await store.items(on: closed).isEmpty)
        #expect(try await store.card(card)?.sorted == true)
    }

    /// The card went to the trash: placed nowhere, still marked sorted
    @Test func trashedCardIsNotPlaced() async throws {
        let board = try await store.createBoard("配色").id!
        try await store.trash([card])
        #expect(try await store.recordSorting(card, placements: placements([board])).isEmpty)
        #expect(try await store.items(on: board).isEmpty)
        #expect(try await store.card(card)?.sorted == true)
    }

    /// Undo: all placements in this batch are removed, the card stays sorted
    @Test func undoKeepsCardSorted() async throws {
        let a = try await store.createBoard("配色").id!, b = try await store.createBoard("字体").id!
        let written = try await store.recordSorting(card, placements: placements([a, b]))
        try await store.removePlacements(written.compactMap(\.id))
        #expect(try await store.boards(containing: card).isEmpty)
        #expect(try await store.card(card)?.sorted == true)
    }

    /// The newly-added mark is cleared when the card leaves the board
    @Test func unseenClears() async throws {
        let a = try await store.createBoard("配色").id!
        _ = try await store.recordSorting(card, placements: placements([a]))
        #expect(try await store.items(on: a).first?.placement.unseen == true)
        try await store.clearUnseen(on: a)
        #expect(try await store.items(on: a).first?.placement.unseen == false)
    }

    /// The newly-added mark doesn't follow when moved to another board
    @Test func movedPlacementLosesUnseen() async throws {
        let a = try await store.createBoard("配色").id!, b = try await store.createBoard("字体").id!
        var moved = try await store.recordSorting(card, placements: placements([a]))[0]
        moved.boardID = b
        try await store.place([moved])
        #expect(try await store.items(on: b).first?.placement.unseen == false)
    }

    /// "Sort These Cards" only handles cards not on any board
    @Test func resortOnlyTouchesUnplacedCards() async throws {
        let board = try await store.createBoard("配色").id!
        var m = Material(kind: .text)
        m.text = "放在画板里的"
        guard case .created(let placed) = try await store.collect(m, into: board, frame: .zero) else { throw CancellationError() }
        _ = try await store.recordSorting(card, placements: [])
        _ = try await store.recordSorting(placed, placements: [])
        #expect(try await store.resortUnplaced() == 1)
        #expect(try await store.card(card)?.sorted == false)
        #expect(try await store.card(placed)?.sorted == true)
    }

    /// A refetch changed the content: the body must be completed again from the new content
    @Test func refillResetsBodyCompleted() async throws {
        try await store.markBodyCompleted(card)
        var m = Material(kind: .text)
        m.text = "换了的内容"
        _ = try await store.fill(card, with: m)
        #expect(try await store.card(card)?.bodyCompleted == false)
    }
}

/// Upgrade: existing cards all count as sorted and body-completed, and no placements have the newly-added mark
@Test func migrationMarksExistingCardsSorted() throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "piyi-migrate-\(UUID().uuidString).sqlite").path
    let db = try DatabaseQueue(path: path)
    try Schema.migrator.migrate(db, upTo: "v5")
    try db.write { db in
        try db.execute(sql: "INSERT INTO card (kind, collectedAt, extraction, tags) VALUES ('text', '2026-01-01', 'complete', '[]')")
        try db.execute(sql: "INSERT INTO board (name, createdAt, openedAt) VALUES ('A', '2026-01-01', '2026-01-01')")
        try db.execute(sql: "INSERT INTO placement (boardID, cardID, x, y, width, height, rotation, z) VALUES (1, 1, 0, 0, 1, 1, 0, 0)")
    }
    try Schema.migrator.migrate(db)
    try db.read { db in
        let card = try #require(try Card.fetchOne(db, key: 1))
        #expect(card.sorted && card.bodyCompleted)
        #expect(try Placement.fetchOne(db, key: 1)?.unseen == false)
    }
}
