import Testing
import Foundation
@testable import Library

/// 段落只有一份切法：发给模型的编号和放大查看里滚到的那一段对得上
@Suite struct PassageTests {
    func card(_ kind: Kind, body: String? = nil, transcript: String? = nil, text: String? = nil, format: String? = nil) -> Card {
        var card = Card(kind: kind)
        (card.body, card.transcript, card.text, card.format) = (body, transcript, text, format)
        return card
    }

    @Test func articleDropsCreditsAndImageMarks() {
        let body = ["👤 采访: 壹小姐", Article.imageMark, "第一段", "", "第二段", Article.imageMark].joined(separator: "\n")
        let passages = Passages.of(card(.web, body: body, format: "公众号"))
        #expect(passages.map(\.label) == ["p1", "p2"])
        #expect(passages.map(\.text) == ["第一段", "第二段"])
        // 不是公众号的署名样子的行照常算一段
        #expect(Passages.of(card(.web, body: "作者：某某\n正文")).count == 2)
    }

    @Test func videoHasDescriptionThenTranscript() {
        let passages = Passages.of(card(.video, body: "简介", transcript: "00:00 开头\n01:25 后面"))
        #expect(passages.map(\.label) == ["p1", "t1", "t2"])
        #expect(passages.map(\.seconds) == [nil, 0, 85])
    }

    @Test func noteAndImage() {
        #expect(Passages.of(card(.text, text: "第一行\n第二行")).map(\.text) == ["第一行", "第二行"])
        #expect(Passages.of(card(.image, body: "图中文字")).isEmpty)
    }

    @Test func quoteFoundAfterBodyChanged() {
        let old = card(.web, body: "甲\n乙段的原话\n丙")
        #expect(Passages.find("乙段的原话", part: .body, in: old)?.number == 2)
        // 前面多出一段：编号变了，原话还在
        let changed = card(.web, body: "新加的一段\n甲\n乙段的原话，后面还补了几个字\n丙")
        #expect(Passages.find("乙段的原话", part: .body, in: changed)?.number == 3)
        #expect(Passages.find("完全没有的话", part: .body, in: changed) == nil)
    }
}

@Suite struct DiscussionStoreTests {
    func note(_ store: Store, _ text: String) async throws -> Int64 {
        let board = try await store.createBoard("A").id!
        return try await store.createNote(text, on: board, frame: someFrame).cardID!
    }

    /// 对话开始前放上桌只改桌；开始后放上、拿下，桌和讨论记录一起改
    @Test func deskAndRecordChangeTogether() async throws {
        let store = try temporaryStore()
        let (a, b) = (try await note(store, "甲"), try await note(store, "乙"))
        let id = try await store.startDiscussion(desk: [a], opening: [.question("问")])
        #expect(try await store.placeOnDesk([a, b], of: id) == [b])
        try await store.takeOffDesk(a, of: id)
        try await store.takeOffDesk(a, of: id)
        #expect(try await store.desk(of: id).map(\.id) == [b])
        let events = try await store.events(of: id)
        #expect(events.map(\.seq) == [1, 2, 3])
        #expect(events.map(\.what) == [.question("问"), .placed(CardMention(card: b, title: "乙")), .removed(CardMention(card: a, title: "甲"))])
    }

    /// 新回答：最后一条回答比看过的新；看过就灭
    @Test func unreadAndArchived() async throws {
        let store = try temporaryStore()
        let id = try await store.startDiscussion(desk: [], opening: [.question("问")])
        #expect(try await store.discussions().first?.unread == false)
        let written = try await store.append([.answer(Answer(text: "答", citations: []))], to: id)
        #expect(try await store.discussions().first?.unread == true)
        try await store.markSeen(id, through: written[0].seq)
        let summary = try #require(try await store.discussions().first)
        #expect(!summary.unread)
        #expect(!summary.isArchived())
        #expect(summary.isArchived(now: .now.addingTimeInterval(DiscussionSummary.archiveAfter + 60)))
    }

    /// 进了废纸篓的卡还在桌上；清空废纸篓时桌上那一条跟着删，记录里的旧提及留着
    @Test func trashedCardStaysUntilPurged() async throws {
        let store = try temporaryStore()
        let a = try await note(store, "甲")
        let id = try await store.startDiscussion(desk: [a], opening: [.question("问")])
        try await store.trash([a])
        #expect(try await store.desk(of: id).first?.trashedAt != nil)
        #expect(try await store.discussions(about: [a]).map(\.id) == [id])
        try await store.emptyTrash()
        #expect(try await store.desk(of: id).isEmpty)
        #expect(try await store.events(of: id).count == 1)
    }
}
