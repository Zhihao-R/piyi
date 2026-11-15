import Testing
import Foundation
import CoreGraphics
import ImageIO
import Synchronization
@testable import Library

/// 第 4 层：前三层判成要浏览器时交给扩展，拿回渲染好的页面再解析一遍。
/// 和网页样本共用录好的网络响应，放在同一个串行的组里
extension WebFixtureTests { @Suite @MainActor struct BrowserLayerTests {
    static let article = "<html><head><title>一篇文章</title></head><body><article><h1>一篇文章</h1>"
        + String(repeating: "<p>这是浏览器里渲染出来的正文，原来靠脚本加载，App 自己下载时只有一个空壳。</p>", count: 12)
        + "</article></body></html>"
    static let shell = "<html><head><title>App</title></head><body><div id=\"root\"></div><script src=\"/app.js\"></script></body></html>"

    @Test func scriptPageIsReadInBrowser() async {
        serve(["https://example.com/app": Self.shell])
        let browser = FakeBrowser(html: Self.article)
        let m = await WebExtractor(session: Replay.session, browser: browser).material(for: URL(string: "https://example.com/app")!)
        #expect(m.partial == nil)
        #expect(m.title == "一篇文章")
        #expect((m.body ?? "").contains("浏览器里渲染出来的正文"))
        #expect(browser.requests == [.init(url: "https://example.com/app", scroll: true)])
    }

    @Test func noBrowserKeepsWaitingForExtension() async {
        serve(["https://example.com/app": Self.shell])
        let m = await WebExtractor(session: Replay.session, browser: FakeBrowser(html: nil)).material(for: URL(string: "https://example.com/app")!)
        #expect(m.partial == .needsBrowser)
    }

    @Test func emptyInBrowserTooStopsWaiting() async {
        serve(["https://example.com/app": Self.shell])
        let m = await WebExtractor(session: Replay.session, browser: FakeBrowser(html: Self.shell)).material(for: URL(string: "https://example.com/app")!)
        #expect(m.partial == .failed("浏览器里打开也没读到内容"))
    }

    @Test func offlineDoesNotAskBrowser() async {
        serve([:])
        let browser = FakeBrowser(html: Self.article)
        let m = await WebExtractor(session: Replay.session, browser: browser).material(for: URL(string: "https://example.com/app")!)
        #expect(m.partial == .offline)
        #expect(browser.requests.isEmpty)
    }

    /// 浏览器连着但没读成：显示真实原因，不再说「等扩展」
    @Test func browserFailureShowsReason() async {
        serve(["https://example.com/app": Self.shell])
        let m = await WebExtractor(session: Replay.session, browser: FakeBrowser(html: Self.article, failing: true))
            .material(for: URL(string: "https://example.com/app")!)
        #expect(m.partial == .failed("浏览器里没读成：读这个网页超时了"))
    }

    /// 网页不存在：浏览器里打开也一样，不占它的队；被网站拦下（403）才交给浏览器
    @Test func onlyBlockedPagesGoToBrowser() async {
        for (status, asked) in [(404, false), (503, false), (403, true)] {
            Replay.responses = ["https://example.com/x": Replay.Recorded(status: status, contentType: "text/html", finalURL: "https://example.com/x",
                                                                           body: Data("<html><title>出错</title></html>".utf8))]
            let browser = FakeBrowser(html: Self.article)
            _ = await WebExtractor(session: Replay.session, browser: browser).material(for: URL(string: "https://example.com/x")!)
            #expect(browser.requests.isEmpty != asked, "状态码 \(status)")
        }
    }

    @Test func completePageNeverOpensBrowser() async {
        serve(["https://example.com/post": Self.article])
        let browser = FakeBrowser(html: nil)
        let m = await WebExtractor(session: Replay.session, browser: browser).material(for: URL(string: "https://example.com/post")!)
        #expect(m.partial == nil)
        #expect(browser.requests.isEmpty)
    }

    /// 小红书：App 自己拿到的是登录页；浏览器里读页面自带的数据，正文干净、配图一张不少，不用滚到底
    @Test func xiaohongshuNoteFromPageData() async {
        let note = "https://www.xiaohongshu.com/explore/abc?xsec_token=t"
        let images = (1...3).map { "https://sns-webpic-qc.xhscdn.com/\($0)" }
        // 页面数据里的图片地址是 http 的，App 要换成 https 去下
        let page = Self.xiaohongshuPage(images: images.map { $0.replacingOccurrences(of: "https://", with: "http://") })
        serve([note: "<html><head><meta name=\"og:title\" content=\"小红书 - 你的生活指南\"></head><body>登录后查看更多</body></html>"],
              images: images)
        let browser = FakeBrowser(html: page)
        let m = await WebExtractor(session: Replay.session, browser: browser).material(for: URL(string: note)!)
        #expect(m.partial == nil)
        #expect(m.kind == .image)
        #expect(m.format == "小红书")
        #expect(m.source == "配色研究所")
        #expect(m.images.count == 3)
        #expect(m.body == "灰调里的绿\n三种低饱和的绿，配米白最安静。 #配色 #设计")
        #expect(browser.requests.first?.scroll == false)
    }

    /// 在浏览器里点「收进拼贴」：页面已经渲染好，不再下载
    @Test func renderedPageIsParsedDirectly() async {
        let images = ["https://sns-webpic-qc.xhscdn.com/1"]
        serve([:], images: images)
        let page = RenderedPage(url: URL(string: "https://www.xiaohongshu.com/explore/abc")!, html: Self.xiaohongshuPage(images: images))
        let m = await WebExtractor(session: Replay.session).material(rendered: page)
        #expect(m.partial == nil)
        #expect(m.images.count == 1)
        #expect(m.url == "https://www.xiaohongshu.com/explore/abc")
    }

    /// 在浏览器里收 B 站页面：页面上没写自己是视频，照样走平台接口，收成视频卡（之后才会取字幕）；接口不通再解析页面
    @Test func renderedPlatformPageUsesPlatformAPI() async {
        let url = "https://www.bilibili.com/video/BV15Zpb6iEd6/?spm_id_from=333"
        let page = RenderedPage(url: URL(string: url)!, html: BrowserLayerTests.article)
        serve(["https://api.bilibili.com/x/web-interface/view?bvid=BV15Zpb6iEd6":
               #"{"code":0,"data":{"bvid":"BV15Zpb6iEd6","title":"科教频道","desc":"简介","duration":300,"owner":{"name":"UP 主"}}}"#])
        let m = await WebExtractor(session: Replay.session).material(rendered: page)
        #expect(m.kind == .video)
        #expect(m.title == "科教频道")
        #expect(m.duration == 300)
        #expect(m.url == url)

        serve([:])
        let parsed = await WebExtractor(session: Replay.session).material(rendered: page)
        #expect(parsed.kind == .web)
        #expect(parsed.title == "一篇文章")
    }

    @Test func cleansXiaohongshuText() {
        #expect(WebExtractor.cleanXiaohongshu("好看[赞R][笑哭R] #配色[话题]# #灰绿[话题]#\n") == "好看 #配色 #灰绿")
    }

    static func xiaohongshuPage(images: [String]) -> String {
        let state: [String: Any] = ["note": ["noteDetailMap": ["abc": ["note": [
            "title": "灰调里的绿", "desc": "三种低饱和的绿，配米白最安静。 #配色[话题]# #设计[话题]#[赞R]", "type": "normal",
            "user": ["nickname": "配色研究所"], "imageList": images.map { ["urlDefault": $0] },
        ]]]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        return "<html><head><title>灰调里的绿 - 小红书</title></head><body><div id=\"app\">…</div>"
            + "<script>window.__INITIAL_STATE__=\(json.replacingOccurrences(of: "null", with: "undefined"))</script>"
            + "<div>猜你想搜</div><div>3天前 浙江</div></body></html>"
    }

    /// 录好的网页，加几张 400×300 的图
    private func serve(_ pages: [String: String], images: [String] = []) {
        Replay.responses = Dictionary(uniqueKeysWithValues: pages.map { url, html in
            (url, Replay.Recorded(status: 200, contentType: "text/html", finalURL: url, body: Data(html.utf8)))
        })
        for url in images { Replay.responses[url] = Replay.Recorded(status: 200, contentType: "image/png", finalURL: url, body: Self.png) }
    }

    static let png: Data = {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.6, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()
} }

/// 假的浏览器：html 为 nil 表示没有连上的浏览器。answers：带登录状态请求各网址时回的原文
final class FakeBrowser: PageBrowser {
    struct Request: Equatable { var url: String, scroll: Bool }
    struct Timeout: LocalizedError { var errorDescription: String? { "读这个网页超时了" } }
    let html: String?
    let failing: Bool
    let answers: [String: String]
    private let log = Mutex<[Request]>([])
    var requests: [Request] { log.withLock { $0 } }

    init(html: String?, failing: Bool = false, answers: [String: String] = [:]) { self.html = html; self.failing = failing; self.answers = answers }

    func render(_ url: URL, scroll: Bool) async throws -> RenderedPage? {
        log.withLock { $0.append(Request(url: url.absoluteString, scroll: scroll)) }
        if failing { throw Timeout() }
        return html.map { RenderedPage(url: url, html: $0) }
    }

    func request(_ url: URL) async throws -> String? {
        guard html != nil else { return nil }
        return answers[url.absoluteString]
    }
}
