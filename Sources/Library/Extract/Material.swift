import Foundation

/// The product of extraction: the common intermediate format all sources are turned into, what it looks like before becoming a card
public struct Material: Sendable {
    public var kind: Kind
    public var form: Form?
    public var title: String?
    public var text: String?
    public var body: String?
    public var source: String?
    public var format: String?
    public var pages: Int?
    public var duration: Double?
    /// The collected thing is this URL itself (web pages, direct file links)
    public var url: String?
    /// The URL of the page it's on (images dragged from the browser)
    public var sourceURL: String?
    /// The first is the cover, the rest are the multi-image card's other images
    public var images: [Data] = []
    /// Files to keep as-is (PDF, video, Word…)
    public var original: URL?
    /// Address for playing an online video in the detail view (see Player)
    public var player: String?
    /// Why only part was fetched; nil means complete
    public var partial: Partial?

    public init(kind: Kind) { self.kind = kind }

    /// Content fingerprint: by the original file if there is one, otherwise by the image or text itself when there's no URL. Web pages aren't deduplicated by content
    var fingerprint: String? {
        get throws {
            try Self.fingerprint(original: original.map(FileStore.fingerprint), url: url,
                                 cover: images.first.map(FileStore.fingerprint), text: text)
        }
    }

    /// Content fingerprint rule for duplicate checks: by the original file if there is one, otherwise (with no URL) by the cover, then by the text. Web pages aren't deduplicated by content.
    /// original and cover are passed as fingerprints of the file contents
    static func fingerprint(original: String?, url: String?, cover: String?, text: String?) -> String? {
        original ?? (url == nil ? cover ?? text.map { FileStore.fingerprint(Data($0.utf8)) } : nil)
    }
}

/// Why only part was fetched. Refetched automatically once the condition is met: back online, the extension connected, or you right-click "Fetch Again"
public enum Partial: Codable, Sendable, Equatable {
    /// Offline
    case offline
    /// Got a login page: sign in to this site in the browser, then retry
    case login(site: String)
    /// The page loads via scripts and must be opened by the browser extension
    case needsBrowser
    /// The site returned an error, or some other reason
    case failed(String)
    /// Not fully fetched yet: the app quit halfway through extraction last time, or what was left then was a block page
    case unfinished

    /// Worth fetching again automatically once the extension connects: the browser is exactly what's missing (loads via scripts, or needs login, which the browser may have)
    public var waitsForBrowser: Bool {
        switch self {
        case .needsBrowser, .login: true
        case .offline, .failed, .unfinished: false
        }
    }

    /// Worth fetching again automatically on every open and every time the network comes back
    public var waitsForNetwork: Bool { self == .offline || self == .unfinished }

    /// A sentence for people
    public var reason: String {
        switch self {
        case .offline: String(localized: "断网时收的，联网后自动补全")
        case .login(let site): String(localized: "要登录 \(displayed(site))：去浏览器登录后重试")
        case .needsBrowser: String(localized: "页面要在浏览器里打开才读得到，扩展连上后自动补全")
        case .failed(let why): why
        case .unfinished: String(localized: "还没抓完，联网后自动补全")
        }
    }
}
