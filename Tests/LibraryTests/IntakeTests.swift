import Testing
import Foundation
import Synchronization
import GRDB
@testable import Library

/// Collected in one step, never lost once collected, one card per thing: duplicate check by final URL, recollecting moves it to the top, inbox deleted only after saving, short text with a URL, old block pages
@Suite struct IntakeTests {
    private func page(_ url: String, body: String = "抓到的正文") -> Material {
        var m = Material(kind: .web)
        m.url = url
        m.body = body
        return m
    }

    // MARK: Duplicate check by final URL (4.2)

    /// Collect a long link first, then a short link that redirects to it: after extraction it's recognized as the same, and the placeholder merges into the existing card
    @Test func shortLinkLandingOnCollectedPageIsTheSameCard() async throws {
        let store = try temporaryStore()
        let board = try await store.createBoard("A").id!
        guard case .created(let long) = try await store.collect(page("https://www.bilibili.com/video/BV1Wrp76mEsW/"), into: board, frame: someFrame) else { return }
        let short = try await store.placeholder(.web, url: "https://b23.tv/abc", on: nil, frame: someFrame)
        guard case .duplicate(let existing, _) = try await store.fill(short, with: page("https://www.bilibili.com/video/BV1Wrp76mEsW/?share_source=copy_web")) else {
            Issue.record("应认出是同一个视频"); return
        }
        #expect(existing.id == long)
        #expect(try await store.card(short) == nil)
    }

    /// The short link was collected first: later collecting the long link, then the same short link again, the URL duplicate check finds this card
    @Test func cardCollectedByShortLinkIsFoundByFinalAddress() async throws {
        let store = try temporaryStore()
        let id = try await store.placeholder(.web, url: "https://b23.tv/abc", on: nil, frame: someFrame)
        #expect(try await store.fill(id, with: page("https://www.bilibili.com/video/BV1Wrp76mEsW/")) == .filled)
        #expect(try await store.card(forURL: "https://bilibili.com/video/BV1Wrp76mEsW?vd_source=x")?.id == id)
        #expect(try await store.card(forURL: "https://b23.tv/abc")?.id == id)
        // The URL is still the one you collected; the final URL is recorded as the source
        let card = try #require(try await store.card(id))
        #expect(card.url == "https://b23.tv/abc" && card.sourceURL == "https://www.bilibili.com/video/BV1Wrp76mEsW/")
    }

    /// When not fully fetched, the final URL is often a sign-in page: two different articles both redirecting to the same sign-in page must not be merged
    @Test func partialPagesAreNotMergedByFinalAddress() async throws {
        let store = try temporaryStore()
        var login = page("https://example.com/login", body: "请登录")
        login.partial = .login(site: "example.com")
        let (a, b) = (try await store.placeholder(.web, url: "https://example.com/a", on: nil, frame: someFrame),
                      try await store.placeholder(.web, url: "https://example.com/b", on: nil, frame: someFrame))
        #expect(try await store.fill(a, with: login) == .filled)
        #expect(try await store.fill(b, with: login) == .filled)
        #expect(try await store.card(forURL: "https://example.com/login") == nil)
    }

    /// Dead links redirected to the home page or a parent section: that isn't their final URL. Two different dead links are separate cards, and the home page doesn't count as collected
    @Test func deadLinksRedirectedToTheHomePageStayApart() async throws {
        let store = try temporaryStore()
        let (a, b) = (try await store.placeholder(.web, url: "https://example.com/old/1", on: nil, frame: someFrame),
                      try await store.placeholder(.web, url: "https://example.com/old/2", on: nil, frame: someFrame))
        #expect(try await store.fill(a, with: page("https://example.com/")) == .filled)
        #expect(try await store.fill(b, with: page("https://example.com/")) == .filled)
        #expect(try await store.card(forURL: "https://example.com") == nil)
        let (c, d) = (try await store.placeholder(.web, url: "https://example.com/blog/2020/a", on: nil, frame: someFrame),
                      try await store.placeholder(.web, url: "https://example.com/blog/2020/b", on: nil, frame: someFrame))
        #expect(try await store.fill(c, with: page("https://example.com/blog")) == .filled)
        #expect(try await store.fill(d, with: page("https://example.com/blog")) == .filled)
        #expect(try await store.cards(in: .all).count == 4)
        #expect(try await store.card(c)?.finalKey == nil)
    }

    /// A URL that one card collected and another card redirected to: it's recognized as the card that collected it
    @Test func collectedAddressWinsOverFinalAddress() async throws {
        let store = try temporaryStore()
        let short = try await store.placeholder(.web, url: "https://b23.tv/abc", on: nil, frame: someFrame)
        #expect(try await store.fill(short, with: page("https://www.bilibili.com/video/BV1Wrp76mEsW/")) == .filled)
        // Old data where each was already collected separately
        let long = try await store.db.write { db in
            var card = Card(kind: .web)
            (card.url, card.urlKey, card.extraction) = ("https://www.bilibili.com/video/BV1Wrp76mEsW/", URLKey.of("https://www.bilibili.com/video/BV1Wrp76mEsW/"), .complete)
            try card.insert(db)
            return card.id!
        }
        #expect(try await store.card(forURL: "https://www.bilibili.com/video/BV1Wrp76mEsW/")?.id == long)
        #expect(try await store.card(forURL: "https://b23.tv/abc")?.id == short)
    }

    // MARK: Recollecting (4.5)

    /// Collected again: the collected time stays, a separate time moves it to the top of "All Cards", and a revisit is recorded
    @Test func collectingAgainResurfacesWithoutTouchingCollectedAt() async throws {
        let store = try temporaryStore()
        let intake = Intake(store: store, extractor: Extractor())
        guard case .created(let old, _) = try await intake.collect([.text("先收的")])[0],
              case .created(let new, _) = try await intake.collect([.text("后收的")])[0] else { Issue.record("应新建两张"); return }
        let first = try #require(try await store.card(old)).collectedAt
        #expect(try await store.cards(in: .all).map(\.face.id) == [new, old])

        guard case .existing(let again, _, _) = try await intake.collect([.text("先收的")])[0] else { Issue.record("应认出收过"); return }
        #expect(again.id == old)
        let card = try #require(try await store.card(old))
        #expect(card.collectedAt == first && card.resurfacedAt != nil)
        #expect(try await store.cards(in: .all).map(\.face.id) == [old, new])
        #expect(try await store.cards(in: .unplaced).map(\.face.id) == [old, new])
        let revisits = try await store.db.read { db in try Row.fetchAll(db, sql: "SELECT kind, cardID FROM revisit").map { ($0[0] as String, $0[1] as Int64) } }
        #expect(revisits.map(\.0) == ["recollected"] && revisits.map(\.1) == [old])
    }

    /// Reply only after the duplicate check: new ones say collected, already-collected ones say so; the URL is known after the duplicate check, no waiting for extraction
    @Test func receiptComesAfterDedup() async throws {
        let store = try temporaryStore()
        let intake = Intake(store: store, extractor: Extractor())
        let heard = Mutex<[Receipt]>([])
        let listen: @Sendable (Intake.Event) async -> Void = { if case .judged(let receipt) = $0 { heard.withLock { $0.append(receipt) } } }

        _ = try await intake.collect([.text("一句话"), .ready(page("https://example.com/a"))], report: listen)
        _ = try await intake.collect([.text("一句话")], report: listen)
        _ = try await intake.collect([.text("一句话"), .text("另一句"), .ready(page("https://example.com/a")), .ready(page("https://example.com/a"))], report: listen)
        #expect(heard.withLock { $0 } == [Receipt(new: 2), Receipt(existing: 1), Receipt(new: 1, existing: 2)])
        #expect(Receipt(new: 1).text == "已收进片羽" && Receipt(new: 3).text == "已收进片羽 3 条")
        #expect(Receipt(existing: 1).text == "已经收过，提到了最前")
        #expect(try await store.cards(in: .all).count == 3)
    }

    /// Can't say it's collected if it wasn't saved: the reply counts what wasn't saved, with different wording when nothing was saved
    @Test func failuresAreNotReportedAsCollected() async throws {
        let store = try temporaryStore()
        let heard = Mutex<[Receipt]>([])
        // The original file is gone: the extracted material can't be saved to the file store
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/报告.pdf")
        let outcomes = try await Intake(store: store, extractor: Extractor()).collect([.file(missing), .text("一句话")], report: {
            if case .judged(let receipt) = $0 { heard.withLock { $0.append(receipt) } }
        })
        #expect(heard.withLock { $0 } == [Receipt(new: 1, failed: 1)])
        #expect(!Intake.saved(outcomes))
        #expect(Receipt(new: 1, failed: 1).text == "已收进片羽；有 1 条没存好，下次打开片羽时再试")
        #expect(Receipt(failed: 1).text == "没存好，下次打开片羽时再试" && !Receipt(failed: 1).kept)
        // Collected by right-click in the browser: say what was collected; already collected or not saved use the same sentence as other entry points
        let image = Source.image(png(gray: 0.1), page: nil), words = Source.text("话"), whole = Source.url(URL(string: "https://a.com")!)
        #expect(Receipt(new: 1).text(taking: image) == "已收下这张图" && Receipt(new: 1).text(taking: words) == "已收下这段话")
        #expect(Receipt(new: 1).text(taking: whole) == "已收下这一页")
        #expect(Receipt(existing: 1).text(taking: image) == "已经收过，提到了最前" && Receipt(failed: 1).text(taking: image) == "没存好，下次打开片羽时再试")
    }

    /// The sentence newly brought by a recollect: recorded if the card doesn't have one yet, existing ones untouched
    @Test func wordsBroughtWhenCollectingAgainAreKept() async throws {
        let store = try temporaryStore()
        let intake = Intake(store: store, extractor: Extractor())
        let url = URL(string: "https://example.com/a")!
        guard case .created(let id, _) = try await intake.collect([.ready(page("https://example.com/a"))])[0] else { Issue.record("应新建"); return }
        _ = try await intake.collect([.url(url)])
        #expect(try await store.card(id)?.note == nil)
        _ = try await intake.collect([.mentioned(url, in: "参考 example.com/a 的排版")])
        #expect(try await store.card(id)?.note == "参考 example.com/a 的排版")
        _ = try await intake.collect([.mentioned(url, in: "另一句")])
        #expect(try await store.card(id)?.note == "参考 example.com/a 的排版")
    }

    /// Report as each item is filled, not after the whole batch (4.6)
    @Test func eachSourceIsReportedWhenFilled() async throws {
        let store = try temporaryStore()
        let events = Mutex<[String]>([])
        let outcomes = try await Intake(store: store, extractor: Extractor()).collect([.text("一"), .text("二")], report: { event in
            events.withLock {
                switch event {
                case .admitted: $0.append("占位")
                case .settled: $0.append("填好")
                case .judged: $0.append("回话")
                }
            }
        })
        #expect(events.withLock { $0 } == ["占位", "填好", "填好", "回话"])
        #expect(Intake.saved(outcomes))
    }

    // MARK: Inbox (4.1)

    private func temporaryInbox() -> Inbox {
        Inbox(folder: FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func files(in inbox: Inbox) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: inbox.folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Things saved to the inbox read back unchanged: images with their page, short text with its URL, files as paths only; one collect is one entry, remembering where on the canvas it should land
    @Test func entriesComeBackAsTheyWent() async throws {
        let inbox = temporaryInbox()
        let image = png(gray: 0.3), page = URL(string: "https://example.com/gallery")!, link = URL(string: "https://figma.com/pricing")!
        let spot = Inbox.Spot(board: 7, x: 120, y: -40)
        try await inbox.put([.image(image, page: page), .mentioned(link, in: "参考 figma.com/pricing 的排版"), .text("一句想法"),
                             .imageAt(URL(string: "https://cdn.example.com/a.jpg")!, page: page), .url(link), .file(URL(fileURLWithPath: "/tmp/报告.pdf"))],
                            id: "一次", spot: spot)
        try await inbox.put([.text("另一次")], id: "又一次")
        let seen = Mutex<[Inbox.Arrival]>([])
        await inbox.drain { arrival in seen.withLock { $0.append(arrival) }; return false }
        let arrivals = seen.withLock { $0 }.sorted { $0.sources.count > $1.sources.count }
        try #require(arrivals.count == 2)
        #expect(arrivals.map(\.id) == ["一次", "又一次"] && arrivals.map(\.spot) == [spot, nil] && arrivals.map(\.files.count) == [6, 1])
        let sources = arrivals[0].sources
        try #require(sources.count == 6)
        if case .image(let data, let from) = sources[0] { #expect(data == image && from == page) } else { Issue.record("第 1 样应是图") }
        if case .mentioned(let url, let words) = sources[1] { #expect(url == link && words == "参考 figma.com/pricing 的排版") } else { Issue.record("第 2 样应是带话的网址") }
        if case .text(let words) = sources[2] { #expect(words == "一句想法") } else { Issue.record("第 3 样应是文字") }
        if case .imageAt(let url, let from) = sources[3] { #expect(url.host() == "cdn.example.com" && from == page) } else { Issue.record("第 4 样应是图片地址") }
        if case .url(let url) = sources[4] { #expect(url == link) } else { Issue.record("第 5 样应是网址") }
        if case .file(let url) = sources[5] { #expect(url.path == "/tmp/报告.pdf") } else { Issue.record("第 6 样应是文件") }
    }

    /// What the extension collects is saved as is by the relay: with an image, collect the image; with selected text, a text card with a source; with a whole page, the web page
    @Test func extensionMessagesAreRead() throws {
        func source(_ json: String) throws -> Source? {
            try JSONDecoder().decode(Inbox.Entry.self, from: Data(json.utf8)).source
        }
        guard case .image(let data, let page)? = try source(#"{"type":"collect","id":"1","url":"https://a.com/p","image":"\#(png(gray: 0.2).base64EncodedString())","html":"<p>x</p>"}"#) else {
            Issue.record("带图的应收图"); return
        }
        #expect(data == png(gray: 0.2) && page?.absoluteString == "https://a.com/p")
        guard case .ready(let m)? = try source(#"{"type":"collect","id":"2","url":"https://a.com/p","text":"选中的一段话"}"#) else { Issue.record("应是文字"); return }
        #expect(m.kind == .text && m.text == "选中的一段话" && m.sourceURL == "https://a.com/p" && m.url == nil)
        guard case .imageAt(let address, _)? = try source(#"{"type":"collect","id":"3","url":"https://a.com/p","imageURL":"https://cdn.a.com/1.jpg"}"#) else { Issue.record("应是图片地址"); return }
        #expect(address.absoluteString == "https://cdn.a.com/1.jpg")
        guard case .rendered(let rendered)? = try source(#"{"type":"collect","id":"4","url":"https://a.com/p","html":"<p>x</p>"}"#) else { Issue.record("应是整页"); return }
        #expect(rendered.url.absoluteString == "https://a.com/p")
    }

    /// Files are deleted only after the card is saved to the library: unsaved ones stay and are handed out again next time; ones being collected aren't handed out twice; one failing doesn't affect others
    @Test func filesStayUntilSaved() async throws {
        let inbox = temporaryInbox()
        try await inbox.put([.text("一句想法")], id: "a")
        await inbox.drain { _ in false }
        #expect(files(in: inbox).count == 1, "没存好：留着")

        try await inbox.put([.text("另一句")], id: "b")
        let seen = Mutex<[String?]>([])
        await inbox.drain { arrival in
            seen.withLock { $0.append(arrival.id) }
            // Looked again before collecting finished: ones being collected aren't handed out again
            await inbox.drain { _ in seen.withLock { $0.append("重复") }; return true }
            return arrival.id == "a"
        }
        #expect(seen.withLock { $0 }.sorted { ($0 ?? "") < ($1 ?? "") } == ["a", "b"])
        #expect(files(in: inbox).count == 1, "a 存好了删掉，b 没存好留着")
        await inbox.drain { arrival in arrival.id == "b" }
        #expect(files(in: inbox).isEmpty)
    }

    /// Once a toast is shown it isn't lost: quit after saving to the inbox and placing a placeholder. On next launch, placeholders with a URL stay and ones without are dropped,
    /// the originals in the inbox are recollected to fill in content, one card each
    @Test func interruptedCollectIsCompletedFromTheInbox() async throws {
        let store = try temporaryStore(), inbox = temporaryInbox()
        let intake = Intake(store: store, extractor: Extractor())
        try await inbox.put([.image(png(gray: 0.6), page: URL(string: "https://example.com/gallery")), .text("一句想法"), .url(URL(string: "https://example.com/a")!)], id: "a")
        // Last time: the placeholder was written, quit before content was filled, file not deleted
        _ = try await store.placeholder(.image, sourceURL: "https://example.com/gallery", on: nil, frame: .zero)
        _ = try await store.placeholder(.text, on: nil, frame: .zero)
        let link = try await store.placeholder(.web, url: "https://example.com/a", on: nil, frame: .zero)

        try await store.recoverUnfinished()
        #expect(try await store.cards(in: .all).map(\.face.id) == [link], "有网址的占位卡留着")
        let collected = Mutex(0)
        await inbox.drain { arrival in
            collected.withLock { $0 += 1 }
            // The URL item isn't fetched online in tests: only check that it's recognized as the existing card
            let local = arrival.sources.filter { $0.url == nil }
            guard let known = try? await store.card(forURL: "https://example.com/a"), known.id == link else { return false }
            return (try? await intake.collect(local)).map(Intake.saved) ?? false
        }
        #expect(collected.withLock { $0 } == 1, "收件箱里的原件确实交出来重收了")
        let cards = try await store.db.read { db in try Card.fetchAll(db) }
        #expect(cards.count == 3)
        let image = try #require(cards.first { $0.kind == .image }), text = try #require(cards.first { $0.kind == .text })
        #expect(image.cover != nil && image.sourceURL == "https://example.com/gallery" && image.extraction == .complete, "图补全了")
        #expect(text.text == "一句想法" && text.extraction == .complete, "文字补全了")
        #expect(files(in: inbox).isEmpty)
    }

    /// Things dragged or pasted onto the canvas go through the inbox too: quit midway through extraction, the placeholder is gone, and on next launch it's recollected to the remembered board and lands back there
    @Test func canvasDropSurvivesACrash() async throws {
        let store = try temporaryStore(), inbox = temporaryInbox()
        let board = try await store.createBoard("A").id!
        try await inbox.put([.image(png(gray: 0.7), page: nil)], id: "拖入", spot: Inbox.Spot(board: board, x: 40, y: 60))
        _ = try await store.placeholder(.image, on: board, frame: someFrame)
        try await store.recoverUnfinished()
        #expect(try await store.items(on: board).isEmpty)

        let intake = Intake(store: store, extractor: Extractor())
        await inbox.drain { arrival in
            guard let spot = arrival.spot else { return false }
            let frame = CGRect(x: spot.x, y: spot.y, width: 200, height: 150)
            return (try? await intake.collect(arrival.sources, on: spot.board, frames: { $0.map { _ in frame } })).map(Intake.saved) ?? false
        }
        let items = try await store.items(on: board)
        #expect(items.count == 1 && items[0].placement.frame.origin == CGPoint(x: 40, y: 60))
        let placed = try #require(items[0].placement.cardID)
        let card = try #require(try await store.card(placed))
        #expect(card.cover != nil && card.extraction == .complete)
        #expect(files(in: inbox).isEmpty)
    }

    // MARK: Short text with a URL (4.7)

    @Test func sentenceWithOneLinkKeepsTheSentence() async throws {
        guard case .mentioned(let url, let words)? = FileExtractor.sources(inText: " 参考 figma.com 定价页的排版\n").first else { Issue.record("应收网址并带上这句话"); return }
        #expect(url.absoluteString == "http://figma.com" && words == "参考 figma.com 定价页的排版")
        // Only URLs, one per line: no text to bring along
        if case .url? = FileExtractor.sources(inText: "https://figma.com/pricing\n").first {} else { Issue.record("只有网址时就是网址") }
        #expect(FileExtractor.sources(inText: "https://a.com/1\nb.com/2").compactMap(\.note).isEmpty)

        // The sentence is recorded on the card; extraction and refetching don't touch it
        let store = try temporaryStore()
        let source = Source.mentioned(url, in: words)
        let id = try await store.placeholder(source.kind, url: source.url?.absoluteString, note: source.note, on: nil, frame: .zero)
        #expect(try await store.fill(id, with: page("http://figma.com")) == .filled)
        #expect(try await store.fill(id, with: page("http://figma.com", body: "重新抓到的")) == .filled)
        let card = try #require(try await store.card(id))
        #expect(card.note == "参考 figma.com 定价页的排版" && card.body == "重新抓到的" && card.text == nil)
    }

    // MARK: Old block pages (4.3)

    /// Block pages kept earlier as normal cards: once recognized, only marked partial to await refetching, content untouched (the old content stays if refetching fails);
    /// normal cards whose title happens to contain "安全验证" (with a cover, or a body that isn't short) are left alone; runs only once
    @Test func oldChallengePagesBecomePartialOnce() async throws {
        let store = try temporaryStore()
        func collect(_ url: String, title: String, body: String, cover: CGFloat? = nil, landed: String? = nil) async throws -> Int64 {
            let id = try await store.placeholder(.web, url: url, on: nil, frame: .zero)
            var m = page(landed ?? url, body: body)
            m.title = title
            m.images = cover.map { [png(gray: $0)] } ?? []
            #expect(try await store.fill(id, with: m) == .filled)
            return id
        }
        let weibo = try await collect("https://weibo.com/1/abcdefghi", title: "Sina Visitor System", body: "", cover: 0.1,
                                      landed: "https://passport.weibo.com/visitor/visitor?url=https://weibo.com/1/abcdefghi")
        let cloudflare = try await collect("https://example.com/post", title: "Just a moment...", body: "Checking your browser")
        let withCover = try await collect("https://example.com/shot", title: "安全验证界面的截图", body: "一张图", cover: 0.2)
        let article = try await collect("https://example.com/essay", title: "谈谈安全验证的设计", body: String(repeating: "正文", count: 200))

        try await store.demoteChallengePagesOnce()
        let demoted = try #require(try await store.card(weibo))
        #expect(demoted.partial == .unfinished && demoted.title == "Sina Visitor System" && demoted.cover != nil, "按地址认出；内容留着")
        let other = try #require(try await store.card(cloudflare))
        #expect(other.partial == .unfinished && other.body == "Checking your browser", "按标题认出：没封面、正文很短")
        #expect(try await store.card(withCover)?.partial == nil, "有封面的正常卡不动")
        #expect(try await store.card(article)?.partial == nil, "正文不短的正常卡不动")

        // Runs only once: ones appearing later aren't its concern
        let later = try await collect("https://example.com/later", title: "Just a moment...", body: "")
        try await store.demoteChallengePagesOnce()
        #expect(try await store.card(later)?.partial == nil)
    }
}
