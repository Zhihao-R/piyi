import Testing
import Foundation
import CoreGraphics
@testable import Library

@Suite struct NoteTests {
    @Test func writtenNoteIsPlacedAndSkipsDedupAndSorting() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let a = try await store.createNote("想法", on: board, frame: someFrame)
        let b = try await store.createNote("想法", on: board, frame: someFrame)
        // 同样的话写两遍是两张卡
        #expect(a.cardID != b.cardID)
        let card = try #require(try await store.card(a.cardID!))
        #expect(card.form == .note && card.kind == .text && card.extraction == .complete)
        #expect(card.sorted && card.bodyCompleted && card.fingerprint == nil)
        #expect(try await store.items(on: board).count == 2)
    }

    @Test func savesTextAndTintOnlyOnNotes() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let note = try await store.createNote("旧的", on: board, frame: someFrame).cardID!
        // 网页帖子里只有字的：别人的原话，不能改
        var post = Material(kind: .text)
        post.url = "https://x.com/a/status/1"
        post.text = "别人的原话"
        guard case .created(let quoted) = try await store.collect(post, into: board, frame: someFrame) else { Issue.record("应新建"); return }
        #expect(try await store.notes([note, quoted]) == [Note(card: note, text: "旧的", tint: nil)])
        try await store.saveNotes([Note(card: note, text: "# 新的", tint: "yellow"), Note(card: quoted, text: "改不了", tint: "pink")])
        #expect(try await store.notes([note]) == [Note(card: note, text: "# 新的", tint: "yellow")])
        let original = try #require(try await store.card(quoted))
        #expect(original.text == "别人的原话" && original.tint == nil)
        // 画布读到的外观带着底色
        let face = try await store.items(on: board).compactMap { item -> CardFace? in if case .card(let f) = item.face, f.id == note { f } else { nil } }.first
        #expect(face?.tint == "yellow" && face?.form == .note)
    }

    @Test func pastedTextIsYoursAndEditingFreesTheFingerprint() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        guard case .created(let id) = try await store.collect(FileExtractor.text("粘贴的一段话"), into: board, frame: someFrame) else {
            Issue.record("应新建"); return
        }
        #expect(try await store.notes([id]) == [Note(card: id, text: "粘贴的一段话", tint: nil)])
        // 只换颜色：还是原来那段话，再粘贴一遍仍然认得出
        try await store.saveNotes([Note(card: id, text: "粘贴的一段话", tint: "blue")])
        #expect(try await store.collect(FileExtractor.text("粘贴的一段话"), into: board, frame: someFrame) == .existing(card: id, restored: false, placed: true))
        // 改了字：不再是原来那段话，再粘贴原话是一张新卡
        try await store.saveNotes([Note(card: id, text: "改过的", tint: "blue")])
        guard case .created(let fresh) = try await store.collect(FileExtractor.text("粘贴的一段话"), into: board, frame: someFrame) else {
            Issue.record("应新建"); return
        }
        #expect(fresh != id)
    }

    @Test func editedTextChangesUnderstandingBasis() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let id = try await store.createNote("一", on: board, frame: someFrame).cardID!
        let before = try #require(try await store.card(id)).contentBasis
        try await store.saveNotes([Note(card: id, text: "二", tint: nil)])
        #expect(try #require(try await store.card(id)).contentBasis != before)
    }
}
