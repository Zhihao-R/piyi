import Foundation
import WebKit

/// 正文识别：用 Mozilla Readability（Firefox 阅读模式的算法）解析已经下载好的网页。
/// 只把网页内容交给系统网页组件解析：页面自己的脚本不跑、任何网络请求都拦掉、不带登录状态，读完就丢。
/// 网页组件只能在主线程上创建和调用，解析本身在它自己的进程里做。
@MainActor
enum Readability {
    struct Article: Sendable {
        var title: String?
        var byline: String?
        var siteName: String?
        var text: String
    }

    static func parse(_ html: String, url: URL) async -> Article? {
        guard let script = source, let rules = await blockEverything() else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.add(rules)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        let waiter = Waiter()
        web.navigationDelegate = waiter
        // 基址留空：相对地址不会被解析成真网址去加载；绝对地址的请求由上面的规则拦掉
        web.loadHTMLString(html, baseURL: nil)
        guard await waiter.wait(seconds: 10) else { return nil }
        let call = script + """

            const article = new Readability(document.cloneNode(true)).parse();
            if (!article) { return null; }
            const box = document.createElement('div');
            box.innerHTML = article.content;
            document.body.replaceChildren(box);
            return { title: article.title, byline: article.byline, siteName: article.siteName, text: box.innerText };
            """
        guard let result = try? await web.callAsyncJavaScript(call, contentWorld: .defaultClient) as? [String: Any],
              let text = result["text"] as? String else { return nil }
        return Article(title: result["title"] as? String, byline: result["byline"] as? String,
                       siteName: result["siteName"] as? String, text: clean(text))
    }

    /// 段落之间留一个空行，去掉成堆的空白
    private static func clean(_ text: String) -> String {
        text.replacing(#/[ \t\u{00A0}]+/#, with: " ")
            .replacing(#/ *\n */#, with: "\n")
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let source: String? = Bundle.library?.url(forResource: "Readability", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static var rules: WKContentRuleList?

    /// 拦掉一切网络请求的规则，编译一次
    private static func blockEverything() async -> WKContentRuleList? {
        if let rules { return rules }
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        rules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "piyi-offline", encodedContentRuleList: json)
        return rules
    }

    private final class Waiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?

        func wait(seconds: Double) async -> Bool {
            await withCheckedContinuation { c in
                continuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish(false) }
            }
        }

        private func finish(_ ok: Bool) {
            continuation?.resume(returning: ok)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }
}

extension Bundle {
    /// 资料块的资源包。打包成 .app 后在 Contents/Resources 里，swift run 和测试时在编译目录里
    static let library: Bundle? = {
        let name = "Piyi_Library.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appending(path: name)) { return bundle }
        }
        return Bundle.module
    }()
}
