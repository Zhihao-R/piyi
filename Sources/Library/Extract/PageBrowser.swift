import Foundation

/// Things done through your browser (borrowing its login state): layer 4 opens a web page and lets the page's own scripts finish; fetches platform subtitles that require login.
/// The library module doesn't know about the browser extension; it only states what's needed here, and the app hands in the implementation at launch
public protocol PageBrowser: Sendable {
    /// Open the URL in the background and wait for the page to render (when scroll is true, also scroll to the bottom so lazy-loaded content appears), returning the full page HTML.
    /// Returns nil when no browser is connected; throws if opened but not read
    func render(_ url: URL, scroll: Bool) async throws -> RenderedPage?
    /// Request the URL with login state (without opening a tab), returning the raw response. Returns nil when no browser is connected; throws if the request fails
    func request(_ url: URL) async throws -> String?
}

/// A page rendered by the browser: the final URL (after redirects) and the full page HTML
public struct RenderedPage: Sendable {
    public var url: URL
    public var html: String

    public init(url: URL, html: String) {
        self.url = url
        self.html = html
    }
}
