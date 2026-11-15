import Testing
import Foundation
import Synchronization
import GRDB
@testable import Library

/// 一步收下、收了就不丢、同一样东西只有一张：最终地址查重、重复收提到最前、收件箱存好才删、短句带网址、老的拦截页
@Suite struct IntakeTests {
    private func page(_ url: String, body: String = "抓到的正文") -> Material {
        var m = Material(kind: .web)
        m.url = url
        m.body = body
        return m
    }

    // MARK: 最终地址查重（4.2）

    /// 先收过长链接，再收跳转到它的短链接：抽取完认出是同一样，占位卡并进已有那张
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

    /// 先收的是短链接：以后收长链接、再收同一个短链接，按网址查重都查得到这张
    @Test func cardCollectedByShortLinkIsFoundByFinalAddress() async throws {
        let store = try temporaryStore()
        let id = try await store.placeholder(.web, url: "https://b23.tv/abc", on: nil, frame: someFrame)
        #expect(try await store.fill(id, with: page("https://www.bilibili.com/video/BV1Wrp76mEsW/")) == .filled)
        #expect(try await store.card(forURL: "https://bilibili.com/video/BV1Wrp76mEsW?vd_source=x")?.id == id)
        #expect(try await store.card(forURL: "https://b23.tv/abc")?.id == id)
        // 网址还是你收的那个，最终地址记作出处
        let card = try #require(try await store.card(id))
        #expect(card.url == "https://b23.tv/abc" && card.sourceURL == "https://www.bilibili.com/video/BV1Wrp76mEsW/")
    }

    /// 没抓全时的最终地址常是登录页：两篇不同的文章都跳到同一个登录页，不能并成一张
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

    /// 失效的链接被转到首页、上一级栏目：那不是它的最终地址。两条不同的失效链接各是各的卡，首页也不算收过
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

    /// 一个网址既是这张卡收的、又是那张卡跳到的：认收的就是它的那张
    @Test func collectedAddressWinsOverFinalAddress() async throws {
        let store = try temporaryStore()
        let short = try await store.placeholder(.web, url: "https://b23.tv/abc", on: nil, frame: someFrame)
        #expect(try await store.fill(short, with: page("https://www.bilibili.com/video/BV1Wrp76mEsW/")) == .filled)
        // 早先就各收了一张的老数据
        let long = try await store.db.write { db in
            var card = Card(kind: .web)
            (card.url, card.urlKey, card.extraction) = ("https://www.bilibili.com/video/BV1Wrp76mEsW/", URLKey.of("https://www.bilibili.com/video/BV1Wrp76mEsW/"), .complete)
            try card.insert(db)
            return card.id!
        }
        #expect(try await store.card(forURL: "https://www.bilibili.com/video/BV1Wrp76mEsW/")?.id == long)
        #expect(try await store.card(forURL: "https://b23.tv/abc")?.id == short)
    }

    // MARK: 重复收（4.5）

    /// 又收一次：收集时间不动，另记的时间把它提到「全部卡片」最前，并记一次回看
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

    /// 查过重才回话：新的说收进了，收过的说收过；网址在查重之后就清楚，不等抽取
    @Test func receiptComesAfterDedup() async throws {
        let store = try temporaryStore()
        let intake = Intake(store: store, extractor: Extractor())
        let heard = Mutex<[Receipt]>([])
        let listen: @Sendable (Intake.Event) async -> Void = { if case .judged(let receipt) = $0 { heard.withLock { $0.append(receipt) } } }

        _ = try await intake.collect([.text("一句话"), .ready(page("https://example.com/a"))], report: listen)
        _ = try await intake.collect([.text("一句话")], report: listen)
        _ = try await intake.collect([.text("一句话"), .text("另一句"), .ready(page("https://example.com/a")), .ready(page("https://example.com/a"))], report: listen)
        #expect(heard.withLock { $0 } == [Receipt(new: 2), Receipt(existing: 1), Receipt(new: 1, existing: 2)])
        #expect(Receipt(new: 1).text == "已收进拼贴" && Receipt(new: 3).text == "已收进拼贴 3 条")
        #expect(Receipt(existing: 1).text == "已经收过，提到了最前")
        #expect(try await store.cards(in: .all).count == 3)
    }

    /// 没存进去不能说收下了：回话里数着没存好的，一样都没存好时另有说法
    @Test func failuresAreNotReportedAsCollected() async throws {
        let store = try temporaryStore()
        let heard = Mutex<[Receipt]>([])
        // 原文件不在了：抽取出的素材存不进文件库
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/报告.pdf")
        let outcomes = try await Intake(store: store, extractor: Extractor()).collect([.file(missing), .text("一句话")], report: {
            if case .judged(let receipt) = $0 { heard.withLock { $0.append(receipt) } }
        })
        #expect(heard.withLock { $0 } == [Receipt(new: 1, failed: 1)])
        #expect(!Intake.saved(outcomes))
        #expect(Receipt(new: 1, failed: 1).text == "已收进拼贴；有 1 条没存好，下次打开拼贴时再试")
        #expect(Receipt(failed: 1).text == "没存好，下次打开拼贴时再试" && !Receipt(failed: 1).kept)
        // 浏览器里右键收的：说出收的是什么；收过、没存好时和别的入口同一句
        let image = Source.image(png(gray: 0.1), page: nil), words = Source.text("话"), whole = Source.url(URL(string: "https://a.com")!)
        #expect(Receipt(new: 1).text(taking: image) == "已收下这张图" && Receipt(new: 1).text(taking: words) == "已收下这段话")
        #expect(Receipt(new: 1).text(taking: whole) == "已收下这一页")
        #expect(Receipt(existing: 1).text(taking: image) == "已经收过，提到了最前" && Receipt(failed: 1).text(taking: image) == "没存好，下次打开拼贴时再试")
    }

    /// 重复收时新带来的那句话：卡上还没有就记下，已经有的不动
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

    /// 每一样填完就报一次，不等整批（4.6）
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

    // MARK: 收件箱（4.1）

    private func temporaryInbox() -> Inbox {
        Inbox(folder: FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func files(in inbox: Inbox) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: inbox.folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// 存进收件箱的东西读出来还是原样：图带着所在网页，短句带着网址，文件只记路径；一次收的归成一份，记着要落回画布的哪里
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

    /// 扩展收的由中转程序原样存下：带图的收图，带选中文字的收成有出处的文字卡，带整页的收网页
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

    /// 卡存进资料库才删文件：没存好的留着，下次再交出来；正在收的不重复交；一份没存好不连累别的
    @Test func filesStayUntilSaved() async throws {
        let inbox = temporaryInbox()
        try await inbox.put([.text("一句想法")], id: "a")
        await inbox.drain { _ in false }
        #expect(files(in: inbox).count == 1, "没存好：留着")

        try await inbox.put([.text("另一句")], id: "b")
        let seen = Mutex<[String?]>([])
        await inbox.drain { arrival in
            seen.withLock { $0.append(arrival.id) }
            // 还没收完又来看了一遍：正在收的不再交出来
            await inbox.drain { _ in seen.withLock { $0.append("重复") }; return true }
            return arrival.id == "a"
        }
        #expect(seen.withLock { $0 }.sorted { ($0 ?? "") < ($1 ?? "") } == ["a", "b"])
        #expect(files(in: inbox).count == 1, "a 存好了删掉，b 没存好留着")
        await inbox.drain { arrival in arrival.id == "b" }
        #expect(files(in: inbox).isEmpty)
    }

    /// 提示了就不丢：存进收件箱、放了占位卡之后退出。下次打开，有网址的占位卡留着、没网址的丢掉，
    /// 收件箱里的原件重收一遍把内容补全，每样只有一张
    @Test func interruptedCollectIsCompletedFromTheInbox() async throws {
        let store = try temporaryStore(), inbox = temporaryInbox()
        let intake = Intake(store: store, extractor: Extractor())
        try await inbox.put([.image(png(gray: 0.6), page: URL(string: "https://example.com/gallery")), .text("一句想法"), .url(URL(string: "https://example.com/a")!)], id: "a")
        // 上一次：占位卡写进去了，内容还没填就退出，文件没删
        _ = try await store.placeholder(.image, sourceURL: "https://example.com/gallery", on: nil, frame: .zero)
        _ = try await store.placeholder(.text, on: nil, frame: .zero)
        let link = try await store.placeholder(.web, url: "https://example.com/a", on: nil, frame: .zero)

        try await store.recoverUnfinished()
        #expect(try await store.cards(in: .all).map(\.face.id) == [link], "有网址的占位卡留着")
        let collected = Mutex(0)
        await inbox.drain { arrival in
            collected.withLock { $0 += 1 }
            // 网址那一样在测试里不去联网抓：只看它被认出是已有的那张
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

    /// 拖进、粘贴到画布上的也先进收件箱：抽取到一半退出，占位卡没了，下次打开按记着的画板重收，落回那个画板
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

    // MARK: 短句带网址（4.7）

    @Test func sentenceWithOneLinkKeepsTheSentence() async throws {
        guard case .mentioned(let url, let words)? = FileExtractor.sources(inText: " 参考 figma.com 定价页的排版\n").first else { Issue.record("应收网址并带上这句话"); return }
        #expect(url.absoluteString == "http://figma.com" && words == "参考 figma.com 定价页的排版")
        // 只有网址、一行一个网址：没有话可带
        if case .url? = FileExtractor.sources(inText: "https://figma.com/pricing\n").first {} else { Issue.record("只有网址时就是网址") }
        #expect(FileExtractor.sources(inText: "https://a.com/1\nb.com/2").compactMap(\.note).isEmpty)

        // 那句话记在卡上，抽取、重新抓取都不动它
        let store = try temporaryStore()
        let source = Source.mentioned(url, in: words)
        let id = try await store.placeholder(source.kind, url: source.url?.absoluteString, note: source.note, on: nil, frame: .zero)
        #expect(try await store.fill(id, with: page("http://figma.com")) == .filled)
        #expect(try await store.fill(id, with: page("http://figma.com", body: "重新抓到的")) == .filled)
        let card = try #require(try await store.card(id))
        #expect(card.note == "参考 figma.com 定价页的排版" && card.body == "重新抓到的" && card.text == nil)
    }

    // MARK: 老的拦截页（4.3）

    /// 以前被当成正常卡留下的拦截页：认出来只标成残缺等重新抓，内容不动（重抓失败时旧的还在）；
    /// 标题里碰巧有「安全验证」的正常卡（有封面，或者正文不短）不动；只做一次
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

        // 只做一次：之后再出现的不归它管
        let later = try await collect("https://example.com/later", title: "Just a moment...", body: "")
        try await store.demoteChallengePagesOnce()
        #expect(try await store.card(later)?.partial == nil)
    }
}
