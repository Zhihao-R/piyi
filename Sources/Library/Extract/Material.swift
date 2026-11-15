import Foundation

/// 抽取的产物：各种来源统一成的中间格式，存成卡片前的样子
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
    /// 收进来的就是这个网址（网页、直链文件）
    public var url: String?
    /// 所在页面的网址（从浏览器拖来的图）
    public var sourceURL: String?
    /// 第一张是封面，其余是多图卡的其余图片
    public var images: [Data] = []
    /// 需要原样保留的文件（PDF、视频、Word…）
    public var original: URL?
    /// 网上的视频在放大查看里播放用的地址（见 Player）
    public var player: String?
    /// 只拿到一部分时的原因；nil 表示完整
    public var partial: Partial?

    public init(kind: Kind) { self.kind = kind }

    /// 内容指纹：有原文件按原文件，没有网址的图片和文字按图片、文字本身。网页不按内容查重
    var fingerprint: String? {
        get throws {
            try Self.fingerprint(original: original.map(FileStore.fingerprint), url: url,
                                 cover: images.first.map(FileStore.fingerprint), text: text)
        }
    }

    /// 查重用的内容指纹规则：有原文件按原文件，没有网址的按封面、再按文字。网页不按内容查重。
    /// original、cover 传的是文件内容的指纹
    static func fingerprint(original: String?, url: String?, cover: String?, text: String?) -> String? {
        original ?? (url == nil ? cover ?? text.map { FileStore.fingerprint(Data($0.utf8)) } : nil)
    }
}

/// 只拿到一部分的原因。条件满足后自动重新抓取：联网了、扩展连上了，或者你右键「重新抓取」
public enum Partial: Codable, Sendable, Equatable {
    /// 断网
    case offline
    /// 拿到的是登录页：去浏览器登录这个网站后重试
    case login(site: String)
    /// 页面靠脚本加载，要交给浏览器扩展打开
    case needsBrowser
    /// 网站报错或者别的原因
    case failed(String)
    /// 还没抓完：上次抽取到一半就退出了，或者当时留下的是拦截页
    case unfinished

    /// 扩展连上后值得自动再抓一次：缺的正是浏览器（靠脚本加载，或者要登录、浏览器里可能登录过）
    public var waitsForBrowser: Bool {
        switch self {
        case .needsBrowser, .login: true
        case .offline, .failed, .unfinished: false
        }
    }

    /// 每次打开、每次联网时值得自动再抓一次
    public var waitsForNetwork: Bool { self == .offline || self == .unfinished }

    /// 给人看的一句话
    public var reason: String {
        switch self {
        case .offline: "断网时收的，联网后自动补全"
        case .login(let site): "要登录 \(site)：去浏览器登录后重试"
        case .needsBrowser: "页面要在浏览器里打开才读得到，扩展连上后自动补全"
        case .failed(let why): why
        case .unfinished: "还没抓完，联网后自动补全"
        }
    }
}
