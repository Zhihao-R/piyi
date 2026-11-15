// 通信格式：App、扩展中转程序、浏览器扩展三方之间的消息，以及两段连接怎么走。
// 浏览器 ↔ 中转程序：浏览器的本机通信协议（Native Messaging），4 字节小端长度 + JSON。
// 中转程序 ↔ App：Unix socket，一行一条 JSON。
// 扩展那边（Extension/src/wire.ts）照着同一份字段写。
import Foundation

public enum Bridge {
    /// 浏览器按这个名字找登记文件，扩展按它连中转程序
    public static let hostName = "local.collage.relay"
    /// 扩展的编号，由 Extension/manifest.json 里的 key 决定，固定不变。登记文件只允许它连
    public static let extensionID = "hoiclamefncicnbdlbaelhlacodfkdgp"

    /// socket、收件箱、装给浏览器的扩展都在这里，只给当前用户。
    /// 测试时用环境变量 COLLAGE_BRIDGE 换一个目录，不碰正在用的 App
    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["COLLAGE_BRIDGE"] { return URL(fileURLWithPath: custom) }
        return URL.applicationSupportDirectory.appending(path: "Collage Bridge", directoryHint: .isDirectory)
    }

    public static func socket(in directory: URL) -> String { directory.appending(path: "app.sock").path }
    /// 本机收件箱：扩展送来的「收集」由中转程序存在这里，App 自己收的（快捷键、服务菜单）也存在这里；卡存进资料库才删
    public static func inbox(in directory: URL) -> URL { directory.appending(path: "inbox", directoryHint: .isDirectory) }

    /// 浏览器收中转程序的单条消息最多 1 MB（反方向，扩展发给中转程序，上限 64 MB）
    public static let maxMessageToBrowser = 1024 * 1024

    public static func prepare(_ directory: URL) {
        try? FileManager.default.createDirectory(at: inbox(in: directory), withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        chmod(inbox(in: directory).path, 0o700)
    }
}

/// 三方共用的一种消息：按 type 区分，各种消息只用到其中几个字段
public struct Message: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// 中转程序连上 App 后的第一句：哪个浏览器启动了它
        case relay
        /// 扩展的招呼：是哪一版
        case hello
        /// App → 扩展：在后台打开这个网址，读出页面
        case fetch
        /// App → 扩展：带着浏览器里的登录状态请求这个网址（不开标签页），交回响应原文。B 站的字幕地址要登录才给
        case request
        /// 扩展 → App：抓取结果
        case result
        /// 扩展 → 中转程序：你在浏览器里点了「收进拼贴」。url 是所在的网页；带 image、imageURL 的收这张图，带 text 的收这段话，
        /// 带 html 的收整页。中转程序存进收件箱，再转给 App 一条只有编号的，叫它去看收件箱
        case collect
        /// 回给扩展，按 collect 的编号对上，先后两条。中转程序：存进收件箱了没有（ok），queued 说 App 是不是没开（没存下、没开就只有这一条）。
        /// App：查过重了。要显示的那句话都在 say 里，扩展只管显示；ok 为 false 是没收成
        case collected
        /// App → 扩展：装了新版，重新加载
        case reload
    }

    public var type: Kind
    public var id: String?
    public var url: String?
    /// 渲染完的整页 HTML
    public var html: String?
    /// 网页上选中的一段话
    public var text: String?
    /// 图片本身（JSON 里是 base64）
    public var image: Data?
    /// 扩展没取到图片本身时，图片的地址
    public var imageURL: String?
    /// 请求到的响应原文
    public var body: String?
    public var ok: Bool?
    public var error: String?
    /// 抓取前要不要滚到底（懒加载的长页面要，页面数据里就有全部内容的平台不用）
    public var scroll: Bool?
    public var browser: String?
    public var version: String?
    public var queued: Bool?
    /// 给人看的一句话：扩展原样显示在网页上
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
