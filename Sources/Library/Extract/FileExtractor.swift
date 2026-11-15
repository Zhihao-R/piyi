import AppKit
import AVFoundation
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 本地文件、图片、文字 → 素材。按内容长什么样分类，不按来源
public enum FileExtractor {
    /// 正文、转录最多留这么多字。讨论要读全文（一段 95 分钟的分享约 3 万字）；理解和搜索各自只取开头一段，
    /// 这道线只挡几百页的 PDF 把资料库撑大
    public static let bodyLimit = 200_000

    /// 抽取器自己下载的临时文件放这里，存进文件库后删掉
    static let downloads: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "collage-downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 一个文件，或一个文件夹里的文件（最多 40 个）
    public static func files(in url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
        // 数到 40 个就停，不进 .app、.rtfd 这类包的内部
        var out: [URL] = []
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while out.count < 40, let file = walk?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true || (try? file.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { out.append(file) }
        }
        return out
    }

    /// 从别处送来的一个文件（手机快捷指令存进收件箱的）→ 要收的东西。
    /// 快捷指令把分享的链接和文字存成 .txt，按文字收；其它文件和拖进来的一样收。
    /// 读不到（iCloud 里的文件还没下载下来）返回 nil，过会儿再试
    public static func sources(fromShared file: URL) -> [Source]? {
        guard file.pathExtension.lowercased() == "txt" else { return [.file(file)] }
        guard let data = try? Data(contentsOf: file) else { return nil }
        // 不是 UTF-8 的（比如 GBK）让系统猜编码；猜不出就当普通文件收，不留在收件箱里反复失败
        guard let text = String(data: data, encoding: .utf8) ?? guessedText(data) else { return [.file(file)] }
        return sources(inText: text)
    }

    private static func guessedText(_ data: Data) -> String? {
        var text: NSString?
        guard NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &text, usedLossyConversion: nil) != 0 else { return nil }
        return text as String?
    }

    /// 一段文字：指向网页的收成这些网址，否则收成一张文字卡；空白的什么都不收。
    /// 一句话里带着一个网址时收这个网址，整句话记在卡上
    public static func sources(inText text: String) -> [Source] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let urls = urls(in: text)
        if urls.isEmpty { return [.text(text)] }
        let alone = links(in: trimmed).first?.range == trimmed.startIndex..<trimmed.endIndex
        return urls.count == 1 && !alone ? [.mentioned(urls[0], in: trimmed)] : urls.map(Source.url)
    }

    /// 文件按类型猜卡片类型，抽取前先放占位卡用
    public static func kind(of url: URL) -> Kind {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .document
    }

    public static func material(fromFile url: URL) async -> Material {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.uppercased()

        if type.conforms(to: .image), let data = try? Data(contentsOf: url) {
            var m = image(data)
            m.source = url.lastPathComponent
            return m
        }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            var m = Material(kind: .video)
            m.source = url.lastPathComponent      // 文件名多半是 IMG_1234，标题交给模型
            m.format = "本地视频"
            m.original = url
            m.duration = try? await AVURLAsset(url: url).load(.duration).seconds
            if let frame = await frames(of: url, at: [0.12]).first, let jpeg = jpeg(frame) { m.images = [jpeg] }
            return m
        }
        if type.conforms(to: .audio) {
            var m = Material(kind: .audio)
            m.format = ext.isEmpty ? "音频" : ext
            m.source = url.lastPathComponent
            m.original = url
            m.duration = try? await AVURLAsset(url: url).load(.duration).seconds
            return m
        }
        if type.conforms(to: .pdf) { return pdf(url, name: name) }
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) || type.conforms(to: .plainText) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var m = Material(kind: .document)
            m.title = markdownTitle(text) ?? name
            m.body = String(text.prefix(bodyLimit))
            m.source = url.lastPathComponent
            m.format = ["md", "markdown"].contains(url.pathExtension.lowercased()) ? "Markdown" : "文本"
            m.original = url
            return m
        }
        // Word、RTF、OpenDocument、网页存档：系统能直接读成富文本
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            var m = Material(kind: .document)
            m.title = name
            m.body = clean(String(attributed.string.prefix(bodyLimit)))
            m.source = url.lastPathComponent
            m.format = ["DOC", "DOCX"].contains(ext) ? "Word" : ext
            m.original = url
            return m
        }
        // 其它任何文件（Keynote、Excel、设计稿…）：用系统的快速查看缩略图做封面
        var m = Material(kind: .document)
        m.title = name
        m.source = url.lastPathComponent
        m.format = ext.isEmpty ? "文件" : ext
        m.original = url
        m.images = await quickLookThumbnail(url).map { [$0] } ?? []
        return m
    }

    /// 图片数据：顺便认出动图和长图。原样保留，动图靠原文件才能动起来
    public static func image(_ data: Data) -> Material {
        var m = Material(kind: .image)
        m.images = [data]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return m }
        if CGImageSourceGetCount(src) > 1 {
            m.form = .animated
            m.format = "GIF"
        } else if let size = pixelSize(src), size.height / size.width > FileStore.maxAspect {
            m.form = .long
            m.format = "长图"
        }
        return m
    }

    /// 文字：一段话收成一张你的文字卡，之后能改
    public static func text(_ raw: String) -> Material {
        var m = Material(kind: .text)
        m.form = .note
        m.text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(bodyLimit))
        return m
    }

    /// 一段文字是在指向网页，还是一段内容：
    /// - 每一行都是网址（从备忘录复制的一串链接；不带 https:// 的也算）→ 这些网址
    /// - 只有一个网址，其余是短短一句（App 分享出来的「【标题】网址」）→ 这个网址，标题以抓到的为准
    /// - 其余（正文里夹着链接）→ 空：整段按文字收，里面的链接不去抓
    public static func urls(in text: String) -> [URL] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let whole = lines.compactMap { line in links(in: line).first { $0.range == line.startIndex..<line.endIndex }?.url }
        if !lines.isEmpty, whole.count == lines.count { return whole }
        let found = links(in: text)
        guard found.count == 1 else { return [] }
        var rest = text
        rest.removeSubrange(found[0].range)
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).count <= shareTextLimit ? [found[0].url] : []
    }

    /// 分享文字里网址以外的部分最多多长：抖音、小红书的分享文字带标题和一句「复制打开 App」，一百来字
    static let shareTextLimit = 140

    /// 文字里的网页链接（不带 https:// 的补上），邮箱之类的不算
    private static func links(in text: String) -> [(url: URL, range: Range<String.Index>)] {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme), let range = Range(match.range, in: text) else { return nil }
            return (url, range)
        }
    }

    // MARK: 各类文件

    /// 从视频里取几帧（位置是 0～1 的比例）
    public static func frames(of url: URL, at positions: [Double]) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        var out: [CGImage] = []
        for p in positions {
            if let image = try? await generator.image(at: CMTime(seconds: duration * p, preferredTimescale: 600)).image { out.append(image) }
        }
        return out
    }

    /// PDF：页数、首页缩略图、正文（逐页读，够了就停，几百页的书也不会卡）
    private static func pdf(_ url: URL, name: String) -> Material {
        var m = Material(kind: .document)
        m.format = "PDF"
        m.source = url.lastPathComponent
        m.original = url
        guard let doc = PDFDocument(url: url) else { m.title = name; return m }
        m.title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        m.pages = doc.pageCount
        var text = ""
        for i in 0..<doc.pageCount where text.count < bodyLimit { text += (doc.page(at: i)?.string ?? "") + "\n" }
        m.body = clean(String(text.prefix(bodyLimit)))
        if let page = doc.page(at: 0), let tiff = page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox).tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage, let jpeg = jpeg(cg) {
            m.images = [jpeg]
        }
        return m
    }

    private static func quickLookThumbnail(_ url: URL) async -> Data? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 600, height: 800), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return jpeg(rep.cgImage)
    }

    static func markdownTitle(_ text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    /// 抽取出的文字统一清理：嵌入对象的占位符（显示成方块）、控制字符、成堆的空行
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{FFFC}" && ($0.properties.generalCategory != .control || $0 == "\n") }))
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 图片小工具

    /// 显示出来的宽高：手机照片常常横着存、另记「转 90°」的方向标记，这种宽高对调
    public static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { return nil }
        let turned = (p[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    public static func pixelSize(_ data: Data) -> CGSize? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(pixelSize)
    }

    public static func jpeg(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
