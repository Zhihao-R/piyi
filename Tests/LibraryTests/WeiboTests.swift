import Testing
import Foundation
@testable import Library

/// 微博和拦截页：App 自己抓到的是访客验证页，微博领访客身份走详情页的数据，其它网站的拦截页交给浏览器。
/// 和网页样本共用录好的网络响应，放在同一个串行的组里
extension WebFixtureTests { @Suite @MainActor struct WeiboTests {
    static let share = "https://mapp.api.weibo.cn/fx/bb4e966cbc25177949819a33a6161722.html"
    static let visitor = "https://visitor.passport.weibo.cn/visitor/visitor?entry=sinawap&a=enter&url=https%3A%2F%2Fm.weibo.cn%2Fstatus%2F5353848056318699&domain=.weibo.cn"
    static let visitorPage = "<html><head><title>Sina Visitor System</title></head><body><span id=\"message\"></span><script>/* 领访客身份 */</script></body></html>"
    static let picture = "https://wx3.sinaimg.cn/mw2000/a.jpg"

    @Test func findsPostID() {
        let cases: [(String, String?)] = [
            ("https://m.weibo.cn/status/5353848056318699", "5353848056318699"),
            ("https://m.weibo.cn/detail/5353848056318699", "5353848056318699"),
            ("https://weibo.com/7729765190/RmAPHqvMv", "RmAPHqvMv"),
            ("https://share.api.weibo.cn/share/1.html?weibo_id=5353848056318699", "5353848056318699"),
            (Self.visitor, "5353848056318699"),
            ("https://weibo.com/u/7729765190", nil),
            (Self.share, nil),
        ]
        for (url, id) in cases { #expect(WebExtractor.weiboID(URL(string: url)!) == id, "\(url)") }
    }

    /// 手机分享的短链：跟随跳转到验证页，从里面认出帖子；长微博取全文，配图带来源下载
    @Test func sharedLinkReadsPost() async {
        serve(status: ["id": "5353848056318699", "isLongText": true, "text": "比地球更适宜居住的世界？<br />确实有…<a href=\"/status/1\">全文</a>",
                       "user": ["screen_name": "镜子杂谈"], "pics": [["large": ["url": Self.picture]]]])
        Replay.responses["https://m.weibo.cn/statuses/extend?id=5353848056318699"] = json(#"{"ok":1,"data":{"longTextContent":"比地球更适宜居住的世界？<br />确实有，不骗你"}}"#)
        let m = await WebExtractor(session: Replay.session).material(for: URL(string: Self.share)!)
        #expect(m.partial == nil)
        #expect(m.kind == .image)
        #expect(m.body == "比地球更适宜居住的世界？\n确实有，不骗你")
        #expect(m.source == "镜子杂谈")
        #expect(m.format == "微博")
        #expect(m.images.count == 1)
        #expect(m.url == "https://m.weibo.cn/detail/5353848056318699")
    }

    /// 全文取不到：留下前一段，去掉末尾的「全文」，标成没取全
    @Test func longTextUnavailableIsPartial() async {
        serve(status: ["id": "5353848056318699", "isLongText": true, "text": "前一段…<a href=\"/status/1\">全文</a>", "user": ["screen_name": "作者"]])
        let m = await WebExtractor(session: Replay.session).material(for: URL(string: "https://m.weibo.cn/status/5353848056318699")!)
        #expect(m.text == "前一段…")
        #expect(m.partial == .failed("长微博只取到前一段"))
    }

    /// 转发的原帖是长微博：原帖也取全文
    @Test func repostOfLongPostReadsFullOriginal() async {
        serve(status: ["id": "5353848056318699", "text": "转发", "user": ["screen_name": "转发的人"],
                       "retweeted_status": ["id": "42", "isLongText": true, "text": "原帖前一段<a href=\"/status/42\">全文</a>", "user": ["screen_name": "原作者"]]])
        Replay.responses["https://m.weibo.cn/statuses/extend?id=42"] = json(#"{"ok":1,"data":{"longTextContent":"原帖完整的正文"}}"#)
        let m = await WebExtractor(session: Replay.session).material(for: URL(string: "https://m.weibo.cn/status/5353848056318699")!)
        #expect(m.text == "转发\n\n@原作者：原帖完整的正文")
        #expect(m.partial == nil)
    }

    /// 转发的：原帖接在后面，自己没配图就用原帖的
    @Test func repostKeepsOriginal() async {
        serve(status: ["id": "5353848056318699", "text": "说得好", "user": ["screen_name": "转发的人"],
                       "retweeted_status": ["text": "原帖内容", "user": ["screen_name": "原作者"], "pics": [["large": ["url": Self.picture]]]]])
        let m = await WebExtractor(session: Replay.session).material(for: URL(string: "https://m.weibo.cn/status/5353848056318699")!)
        #expect(m.body == "说得好\n\n@原作者：原帖内容")
        #expect(m.images.count == 1)
    }

    /// 领不到访客身份：接口这条路不通，退回通用解析，认出验证页交给浏览器，不把它当内容
    @Test func noVisitorFallsToBrowser() async {
        Replay.responses = [Self.share: page(Self.visitorPage, finalURL: Self.visitor),
                            "https://passport.weibo.com/visitor/genvisitor2": json(#"visitor_gray_callback({"retcode":50000000,"msg":"fail"});"#)]
        let browser = FakeBrowser(html: nil)
        let m = await WebExtractor(session: Replay.session, browser: browser).material(for: URL(string: Self.share)!)
        #expect(m.partial == .needsBrowser)
        #expect(m.title == "mapp.api.weibo.cn")
        #expect(m.url == Self.share)
        #expect(browser.requests.count == 1)
    }

    /// Cloudflare 的人机验证用 503 回：一样交给浏览器；文章标题里出现「安全验证」不算
    @Test func challengePagesGoToBrowser() async {
        let cloudflare = "<html><head><title>Just a moment...</title></head><body><p>Verifying you are human.</p></body></html>"
        Replay.responses = ["https://example.com/a": .init(status: 503, contentType: "text/html", finalURL: "https://example.com/a", body: Data(cloudflare.utf8))]
        let browser = FakeBrowser(html: nil)
        let m = await WebExtractor(session: Replay.session, browser: browser).material(for: URL(string: "https://example.com/a")!)
        #expect(m.partial == .needsBrowser)
        #expect(browser.requests.count == 1)

        let article = "<html><head><title>聊聊安全验证</title></head><body>" + String(repeating: "<p>一段讲人机验证怎么设计的正文。</p>", count: 20) + "</body></html>"
        #expect(!WebExtractor.isChallenge(Page(html: article, url: URL(string: "https://example.com/b")!)))
    }

    private func serve(status: [String: Any]) {
        let data = String(decoding: try! JSONSerialization.data(withJSONObject: [["status": status]]), as: UTF8.self)
        Replay.responses = [
            Self.share: page(Self.visitorPage, finalURL: Self.visitor),
            "https://passport.weibo.com/visitor/genvisitor2": json(#"window.visitor_gray_callback && visitor_gray_callback({"retcode":20000000,"data":{"sub":"s","subp":"p"}});"#),
            "https://m.weibo.cn/detail/5353848056318699": page("<script>var $render_data = \(data)[0] || {};</script>", finalURL: "https://m.weibo.cn/detail/5353848056318699"),
            Self.picture: .init(status: 200, contentType: "image/png", finalURL: Self.picture, body: BrowserLayerTests.png),
        ]
    }

    private func page(_ html: String, finalURL: String) -> Replay.Recorded { .init(status: 200, contentType: "text/html", finalURL: finalURL, body: Data(html.utf8)) }
    private func json(_ body: String) -> Replay.Recorded { .init(status: 200, contentType: "application/json", finalURL: "", body: Data(body.utf8)) }
} }
