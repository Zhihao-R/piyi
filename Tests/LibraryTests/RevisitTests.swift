import Testing
import Foundation
import GRDB
@testable import Library

/// 回看记录：只存不用，但存下来的要对得上，删画板、清废纸篓时不出错
struct RevisitTests {
    private func revisits(_ store: Store) async throws -> [(kind: String, card: Int64, board: Int64?)] {
        try await store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, cardID, boardID FROM revisit ORDER BY id").map { ($0["kind"], $0["cardID"], $0["boardID"]) }
        }
    }

    private func card(_ store: Store, on board: Int64, _ text: String) async throws -> Int64 {
        var note = Material(kind: .text)
        note.text = text
        guard case .created(let id) = try await store.collect(note, into: board, frame: someFrame) else { throw CancellationError() }
        return id
    }

    @Test func eachCardGetsOneRow() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let (a, b) = (try await card(store, on: board, "一"), try await card(store, on: board, "二"))
        try await store.record(.found, [a, b])
        try await store.record(.placed, [a], board: board)
        let rows = try await revisits(store)
        #expect(rows.map(\.kind) == ["found", "found", "placed"])
        #expect(rows.map(\.card) == [a, b, a])
        #expect(rows.map(\.board) == [nil, nil, board])
    }

    /// 画板删了，在那里用过的记录留着；卡清出废纸篓，它的记录跟着走
    @Test func boardsAndCardsGoAway() async throws {
        let store = try temporaryStore()
        let (keep, gone) = (try await store.createBoard("留").id!, try await store.createBoard("删").id!)
        let (a, b) = (try await card(store, on: keep, "一"), try await card(store, on: keep, "二"))
        try await store.record(.placed, [a], board: gone)
        try await store.record(.opened, [b])
        try await store.deleteBoard(gone, trashingOrphans: false)
        try await store.trash([b])
        try await store.emptyTrash()
        let rows = try await revisits(store)
        #expect(rows.map(\.card) == [a])
        #expect(rows.map(\.board) == [nil])
    }
}
