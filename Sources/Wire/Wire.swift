// Message format: messages among the app, the extension relay and the browser extension, and how the two connections work.
// Browser ↔ relay: the browser's native messaging protocol, 4-byte little-endian length + JSON.
// Relay ↔ app: Unix socket, one JSON per line.
// The extension side (Extension/src/wire.ts) follows the same fields.
import Foundation

public enum Bridge {
    /// The browser finds the registration file by this name, and the extension uses it to connect to the relay. Chrome host names can't contain hyphens, so it's zhihao_r, not the zhihao-r in the bundle id
    public static let hostName = "io.github.zhihao_r.piyi.relay"
    /// The extension's ID, determined by the key in Extension/static/manifest.json and fixed. The registration file only allows it to connect
    public static let extensionID = "cbkgaojdimngmgnhhpjbljeeimhabcbb"

    /// The socket, the inbox and the extension installed for browsers all live here, for the current user only.
    /// Tests use the PIYI_BRIDGE environment variable to switch to another folder without touching the running app
    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["PIYI_BRIDGE"] { return URL(fileURLWithPath: custom) }
        return URL.applicationSupportDirectory.appending(path: "Piyi Bridge", directoryHint: .isDirectory)
    }

    public static func socket(in directory: URL) -> String { directory.appending(path: "app.sock").path }
    /// Local inbox: "collect"s from the extension are stored here by the relay, and what the app collects itself (shortcut, Services menu) is stored here too; deleted once the card is saved to the library
    public static func inbox(in directory: URL) -> URL { directory.appending(path: "inbox", directoryHint: .isDirectory) }

    /// The browser accepts at most 1 MB per message from the relay (in the other direction, extension to relay, the limit is 64 MB)
    public static let maxMessageToBrowser = 1024 * 1024

    public static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: inbox(in: directory), withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        chmod(inbox(in: directory).path, 0o700)
    }
}

/// One message type shared by all three: told apart by type, each message using only some of the fields
public struct Message: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The relay's first message after connecting to the app: which browser launched it
        case relay
        /// The extension's hello: which version it is
        case hello
        /// App → extension: open this URL in the background and read the page
        case fetch
        /// App → extension: request this URL with the browser's sign-in state (no tab opened) and return the raw response. Bilibili's subtitle URLs require sign-in
        case request
        /// Extension → app: fetch result
        case result
        /// Extension → relay: you clicked "Collect to Piyi" in the browser. url is the page it's on; with image or imageURL it collects that image, with text that passage,
        /// with html the whole page. The relay stores it in the inbox, then forwards the app a message with just the ID, telling it to check the inbox
        case collect
        /// Replies to the extension, matched by the collect's ID, two in sequence. Relay: whether it was stored in the inbox (ok), and queued says whether the app isn't open (if not stored, or not open, this is the only one).
        /// App: duplicates checked. The sentence to show is all in say; the extension just displays it; ok false means it wasn't collected
        case collected
        /// App → extension: a new version is installed, reload
        case reload
    }

    public var type: Kind
    public var id: String?
    public var url: String?
    /// Fully rendered page HTML
    public var html: String?
    /// A passage selected on the page
    public var text: String?
    /// The image itself (base64 in JSON)
    public var image: Data?
    /// The image's URL, when the extension couldn't get the image itself
    public var imageURL: String?
    /// The raw response that was requested
    public var body: String?
    public var ok: Bool?
    public var error: String?
    /// Whether to scroll to the bottom before fetching (long lazy-loading pages need it; platforms whose page data already has all the content don't)
    public var scroll: Bool?
    public var browser: String?
    public var version: String?
    public var queued: Bool?
    /// A sentence for people: the extension shows it on the page as is
    public var say: String?

    public init(_ type: Kind, id: String? = nil, url: String? = nil, html: String? = nil, text: String? = nil, image: Data? = nil, imageURL: String? = nil,
                body: String? = nil, ok: Bool? = nil, error: String? = nil,
                scroll: Bool? = nil, browser: String? = nil, version: String? = nil, queued: Bool? = nil, say: String? = nil) {
        (self.type, self.id, self.url, self.html, self.body, self.ok, self.error) = (type, id, url, html, body, ok, error)
        (self.text, self.image, self.imageURL) = (text, image, imageURL)
        (self.scroll, self.browser, self.version, self.queued, self.say) = (scroll, browser, version, queued, say)
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data) -> Message? { try? JSONDecoder().decode(Message.self, from: data) }
}
