import Testing
import Foundation
import CoreGraphics
@testable import Library

@Suite struct CollectingTests {
    @Test func partialCardIsRefilledAndOldCoverRemoved() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let id = try await store.placeholder(.web, url: "https://example.com/a", on: board, frame: someFrame)
        var first = Material(kind: .web)
        first.url = "https://example.com/a"
        first.images = [png(gray: 0.1)]
        first.partial = .offline
        #expect(try await store.fill(id, with: first) == .filled)
        let oldCover = try #require(try await store.card(id)?.cover)
        #expect(try await store.partialCards().map(\.id) == [id])

        var second = first
        second.images = [png(gray: 0.9)]
        second.partial = nil
        second.body = "联网后补全的正文"
        #expect(try await store.fill(id, with: second) == .filled)
        #expect(try await store.partialCards().isEmpty)
        #expect(try await store.card(id)?.body == "联网后补全的正文")
        #expect(!FileManager.default.fileExists(atPath: store.files.url(of: oldCover).path))
    }

    @Test func placeholderWithDuplicateContentIsRemoved() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var text = Material(kind: .text)
        text.text = "同一段话"
        guard case .created(let original) = try await store.collect(text, into: board, frame: someFrame) else { return }
        let id = try await store.placeholder(.text, on: board, frame: someFrame)
        guard case .duplicate(let existing, _) = try await store.fill(id, with: text) else { Issue.record("应查到重复"); return }
        #expect(existing.id == original)
        #expect(try await store.card(id) == nil)
        // 占位卡的摆放转给已有那张：同一画板里有两份
        #expect(try await store.items(on: board).map(\.placement.cardID) == [original, original])
    }

    /// 抽取到一半就退出：有网址的占位卡留下、标成残缺，打开后自动重新抓；没网址的丢掉，由收件箱里的原件重收
    @Test func unfinishedPlaceholdersWithURLBecomePartial() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let link = try await store.placeholder(.web, url: "https://example.com/b", note: "看看这个", on: board, frame: someFrame)
        let image = try await store.placeholder(.image, sourceURL: "https://example.com/gallery", on: board, frame: someFrame)
        try await store.recoverUnfinished()
        let kept = try #require(try await store.card(link))
        #expect(kept.extraction == .complete && kept.partial == .unfinished && kept.note == "看看这个")
        #expect(kept.partial?.waitsForNetwork == true)
        #expect(try await store.card(image) == nil)
        #expect(try await store.items(on: board).map(\.placement.cardID) == [link])
        // 重收同一个网址：查重认出它，不出第二张
        #expect(try await store.card(forURL: "https://example.com/b")?.id == link)
    }
}

@Suite struct RefetchTests {
    /// 重新抓取没抓全（比如断网）：已有的封面和正文留着，只更新原因
    @Test func failedRefetchKeepsContent() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var page = Material(kind: .web)
        page.url = "https://example.com/a"
        page.images = [png(gray: 0.4)]
        page.body = "抓到的正文"
        guard case .created(let id) = try await store.collect(page, into: board, frame: someFrame) else { return }
        var offline = Material(kind: .web)
        offline.url = "https://example.com/a"
        offline.partial = .offline
        #expect(try await store.fill(id, with: offline) == .filled)
        let card = try #require(try await store.card(id))
        #expect(card.body == "抓到的正文" && card.cover != nil && card.partial == .offline)
    }

    /// 收坏的卡（拿失败页当内容理解过）重新抓取还是没内容：理解出的标题、描述、向量清掉，不再看着、搜着像抓到了
    @Test func emptyRefetchForgetsUnderstanding() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        let id = try await store.placeholder(.web, url: "https://weibo.com/1/a", on: board, frame: someFrame)
        var page = Material(kind: .web)
        page.title = "Sina Visitor System"
        page.partial = .failed("浏览器里没读成")
        #expect(try await store.fill(id, with: page) == .filled)
        let card = try #require(try await store.card(id))
        try await store.saveUnderstanding(id, basis: card.contentBasis,
                                          generated: Generated(title: "微博访客验证页", caption: "验证提示", detail: nil, tags: ["微博"], summary: nil), colors: nil)
        try await store.saveVector(Vector(cardID: id, model: "m", basis: "b", values: [1]))

        page.title = nil
        page.partial = .needsBrowser
        #expect(try await store.fill(id, with: page) == .filled)
        let refetched = try #require(try await store.card(id))
        #expect(refetched.isEmpty && refetched.generatedTitle == nil && refetched.caption == nil && refetched.tags.isEmpty)
        #expect(try await store.vectorBases()[id] == nil)
    }

    /// 正在重新抓取时退出：下次打开不删这张卡
    @Test func refetchInterruptedKeepsCard() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        var text = Material(kind: .text)
        text.text = "有内容的卡"
        guard case .created(let id) = try await store.collect(text, into: board, frame: someFrame) else { return }
        try await store.markExtracting(id)
        try await store.recoverUnfinished()
        let card = try #require(try await store.card(id))
        #expect(card.extraction == .complete && card.partial == nil)
    }
}
