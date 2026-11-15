import Testing
import Foundation
@testable import Library

/// 网页抽取：网络请求由 Replay 按网址原样返回写好的响应，不联网。
@Suite(.serialized) @MainActor struct WebFixtureTests {}

extension WebFixtureTests {
    /// 断网时收网址：留成残缺卡，原因是断网，网址和标题（网站名）还在
    @Test func offlineGivesPartialCard() async {
        Replay.responses = [:]
        let m = await WebExtractor(session: Replay.session).material(for: URL(string: "https://example.com/post")!)
        #expect(m.partial == .offline)
        #expect(m.url == "https://example.com/post")
        #expect(m.title == "example.com")
    }

    /// 登录页、报错页、空页的判断规则
    @Test func judgesLoginAndEmptyPages() {
        #expect(WebExtractor.judge(status: 200, title: "请登录", text: "扫码登录后查看", hasImage: false, site: "feishu.cn") == .login(site: "feishu.cn"))
        #expect(WebExtractor.judge(status: 404, title: "Not Found", text: String(repeating: "x", count: 300), hasImage: false, site: "a.com") == .failed("网站返回错误（404）"))
        #expect(WebExtractor.judge(status: 200, title: "App", text: "", hasImage: false, site: "a.com") == .needsBrowser)
        #expect(WebExtractor.judge(status: 200, title: "文章", text: String(repeating: "正文", count: 400), hasImage: true, site: "a.com") == nil)
    }

    /// 正文太短不问模型：公众号只取出十几个字算没抓全，登录页照样认得出
    @Test func shortPagesCountAsClipped() {
        let glance = { (url: String, title: String?, text: String) in PageGlance(url: URL(string: url)!, title: title, text: text) }
        #expect(WebExtractor.clipped(glance("https://mp.weixin.qq.com/s/45h_yAgewcSOYSEFhmdBpQ", "爱奇艺与B站：PGC缺牌，UGC缺人", "原创\n 后雨\n 数读社\n 不喜欢"), hasImage: false, site: "mp.weixin.qq.com") == .needsBrowser)
        #expect(WebExtractor.clipped(glance("https://accounts.google.com/v3/signin/identifier", "登录 - Google 账号", "登录使用您的 Google 账号"), hasImage: false, site: "google.com") == .login(site: "google.com"))
        #expect(WebExtractor.clipped(glance("https://passport.bilibili.com/login", "Rsbuild App", ""), hasImage: false, site: "bilibili.com") == .login(site: "bilibili.com"))
        #expect(WebExtractor.clipped(glance("https://www.bilibili.com/video/BV1W4411Y76B/", "用户体验设计师", String(repeating: "简介", count: 20)), hasImage: false, site: "bilibili.com") == nil)
        // 一张大图配一句说明的作品页不算没抓全
        #expect(WebExtractor.clipped(glance("https://dribbble.com/shots/1", "海报", "一张海报"), hasImage: true, site: "dribbble.com") == nil)
    }
}

/// 按网址把写好的响应原样返回；没写的请求当作断网
final class Replay: URLProtocol, @unchecked Sendable {
    struct Recorded { var status: Int, contentType: String, finalURL: String, body: Data }
    nonisolated(unsafe) static var responses: [String: Recorded] = [:]

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Replay.self]
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let r = Self.responses[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: URL(string: r.finalURL) ?? url, statusCode: r.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": r.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension WebFixtureTests {
    /// 公众号正文按原顺序切成文字和配图：段落、排版工具的嵌套 section 都算段，行内标签不断段，别处的图不要
    @Test func splitsArticleIntoTextAndImages() {
        let html = #"""
        <p>第一段</p>
        <section><img data-src="https://mmbiz.qpic.cn/a.jpg&amp;x=1" /></section>
        <p><span>第二</span><strong>段</strong><img data-src="https://mmbiz.qpic.cn/b.jpg"></p>
        <p> </p><img src="https://other.com/c.jpg">
        <section><section><span>排版工具</span>写的段落</section><section>又一段<br>换行</section></section>
        """#
        let blocks = Page.blocks(in: html, image: #"data-src="(https?://mmbiz\.qpic\.cn[^"]+)""#)
        #expect(blocks == [.text("第一段"), .image("https://mmbiz.qpic.cn/a.jpg&x=1"), .text("第二段"), .image("https://mmbiz.qpic.cn/b.jpg"),
                           .text("排版工具写的段落"), .text("又一段"), .text("换行")])
    }
}
