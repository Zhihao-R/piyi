import Foundation
import WebKit

/// Body recognition: parse an already-downloaded web page with Mozilla Readability (the algorithm behind Firefox Reader View).
/// Only the page content is handed to the system web view to parse: the page's own scripts don't run, every network request is blocked, no login state is carried, and it's discarded after reading.
/// The web view can only be created and called on the main thread; the parsing itself happens in its own process.
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
        // Leave the base URL empty: relative addresses won't resolve to real URLs and load; requests to absolute addresses are blocked by the rules above
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

    /// Leave one blank line between paragraphs, drop piles of whitespace
    private static func clean(_ text: String) -> String {
        text.replacing(#/[ \t\u{00A0}]+/#, with: " ")
            .replacing(#/ *\n */#, with: "\n")
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let source: String? = Bundle.library?.url(forResource: "Readability", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static var rules: WKContentRuleList?

    /// Rules blocking all network requests, compiled once
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
    /// The library module's resource bundle. In Contents/Resources once packaged as a .app; in the build folder under swift run and tests
    static let library: Bundle? = {
        let name = "Piyi_Library.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appending(path: name)) { return bundle }
        }
        return Bundle.module
    }()
}
