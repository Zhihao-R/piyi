import Foundation
import CoreGraphics

/// 收集入口交过来的一样东西
public enum Source: Sendable {
    case file(URL)
    case url(URL)
    /// 从浏览器拖来的图：图本身 + 所在页面的网址
    case image(Data, page: URL?)
    /// 网页上的一张图，只知道地址（扩展没取到图本身）：下载下来，出处记所在页面
    case imageAt(URL, page: URL?)
    /// 一句话里带着的网址：收这个网址，那句话记在卡上
    case mentioned(URL, in: String)
    case text(String)
    /// 在浏览器里点了「收进拼贴」：页面已经渲染好
    case rendered(RenderedPage)
    /// 已经抽取好的（示例数据里事先下载好的链接卡）
    case ready(Material)

    /// 抽取前先猜个类型，放占位卡用
    public var kind: Kind {
        switch self {
        case .file(let url): FileExtractor.kind(of: url)
        case .url, .rendered, .mentioned: .web
        case .image, .imageAt: .image
        case .text: .text
        case .ready(let m): m.kind
        }
    }

    /// 收进来的就是这个网址（按网址查重用）
    public var url: URL? {
        switch self {
        case .url(let url), .imageAt(let url, _), .mentioned(let url, _): url
        case .rendered(let page): page.url
        case .ready(let m): m.url.flatMap(URL.init(string:))
        default: nil
        }
    }

    /// 所在页面的网址，记作出处
    public var page: URL? {
        switch self {
        case .image(_, let page), .imageAt(_, let page): page
        default: nil
        }
    }

    /// 和网址一起带来的那句话
    public var note: String? { if case .mentioned(_, let words) = self { words } else { nil } }
}

/// 内容抽取的唯一入口：任何来源 → 素材
public struct Extractor: Sendable {
    let web: WebExtractor
    let models: (any ExtractionModels)?

    public init(session: URLSession = .shared, models: (any ExtractionModels)? = nil, browser: (any PageBrowser)? = nil) {
        web = WebExtractor(session: session, models: models, browser: browser)
        self.models = models
    }

    public func material(for source: Source) async -> Material {
        switch source {
        case .file(let url): await FileExtractor.material(fromFile: url)
        case .url(let url), .mentioned(let url, _): await web.material(for: url)
        case .rendered(let page): await web.material(rendered: page)
        case .image(let data, let page): Self.found(FileExtractor.image(data), on: page)
        case .imageAt(let url, let page): Self.found(await web.material(for: url), on: page)
        case .text(let text): FileExtractor.text(text)
        case .ready(let m): m
        }
    }

    /// 网页上找到的图：出处记所在页面
    private static func found(_ image: Material, on page: URL?) -> Material {
        guard let page else { return image }
        var m = image
        m.sourceURL = page.absoluteString
        m.source = page.host()
        return m
    }
}

extension Extractor {
    /// 补全正文：抽取的最后一步，在后台、较低的优先级做，结果和其它正文一样能搜、能读。做完记在卡上，分拣等它。
    /// 图片卡、扫描版 PDF（有页数没正文）识别图中文字，补进正文；视频、音频有文件的在本机转录，
    /// 平台上的视频不下载，取平台字幕，单独存成转录
    public func completeBody(of id: Int64, in store: Store) async throws {
        guard let card = try await store.card(id) else { return }
        let scanned = card.kind == .document && card.format == "PDF" && (card.body ?? "").count < 50
        if card.kind == .image || scanned, let cover = card.cover {
            var names = [cover]
            if card.kind == .image { names += try await store.images(of: id) }
            var parts: [String] = []
            for name in names { parts.append(await TextRecognition.text(inImageAt: store.files.url(of: name))) }
            try await store.appendRecognizedText(id, parts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        // 同一份内容不再转。重新抓取会换掉正文，那时再取一遍
        if card.kind == .video || card.kind == .audio, card.transcript == nil {
            var cues: [Cue]?
            if let original = card.original {
                cues = await models?.transcribe(store.files.url(of: original))
            } else if let url = card.url.flatMap(URL.init(string:)) {
                cues = await web.subtitles(for: url)
            }
            if let cues { try await store.setTranscript(id, String(Transcript.text(cues).prefix(FileExtractor.bodyLimit))) }
        }
        // 转不出来也算结束：分拣不再等它
        try await store.markBodyCompleted(id)
    }
}
