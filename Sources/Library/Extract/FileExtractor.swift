import AppKit
import AVFoundation
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Local files, images, text → material. Classified by what the content looks like, not by source
public enum FileExtractor {
    /// Keep at most this many characters of body and transcript. Discussions read the full text (a 95-minute talk is about 30,000 characters); understanding and search each take only the opening part,
    /// this limit only stops PDFs of hundreds of pages from bloating the library
    public static let bodyLimit = 200_000

    /// Temporary files the extractor downloads itself go here, deleted once in the file store
    static let downloads: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "piyi-downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// One file, or the files in a folder (at most 40)
    public static func files(in url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
        // Stop at 40, and don't go inside packages like .app or .rtfd
        var out: [URL] = []
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while out.count < 40, let file = walk?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true || (try? file.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { out.append(file) }
        }
        return out
    }

    /// A file sent from elsewhere (saved into the inbox by a phone shortcut) → things to collect.
    /// The shortcut saves shared links and text as .txt, collected as text; other files are collected like dragged-in ones.
    /// Returns nil if unreadable (the iCloud file isn't downloaded yet), to retry later
    public static func sources(fromShared file: URL) -> [Source]? {
        guard file.pathExtension.lowercased() == "txt" else { return [.file(file)] }
        guard let data = try? Data(contentsOf: file) else { return nil }
        // For non-UTF-8 (e.g. GBK), let the system guess the encoding; if it can't, collect it as a plain file instead of leaving it to keep failing in the inbox
        guard let text = String(data: data, encoding: .utf8) ?? guessedText(data) else { return [.file(file)] }
        return sources(inText: text)
    }

    private static func guessedText(_ data: Data) -> String? {
        var text: NSString?
        guard NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &text, usedLossyConversion: nil) != 0 else { return nil }
        return text as String?
    }

    /// A piece of text: if it points to web pages, collect those URLs, otherwise collect one text card; blank collects nothing.
    /// When a sentence carries one URL, collect that URL and record the whole sentence on the card
    public static func sources(inText text: String) -> [Source] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let urls = urls(in: text)
        if urls.isEmpty { return [.text(text)] }
        let alone = links(in: trimmed).first?.range == trimmed.startIndex..<trimmed.endIndex
        return urls.count == 1 && !alone ? [.mentioned(urls[0], in: trimmed)] : urls.map(Source.url)
    }

    /// Guess the card kind from the file type, for the placeholder before extracting
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
            m.source = url.lastPathComponent      // the file name is usually IMG_1234, so the title is left to the model
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
        // Word, RTF, OpenDocument, web archives: the system can read them as rich text directly
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            var m = Material(kind: .document)
            m.title = name
            m.body = clean(String(attributed.string.prefix(bodyLimit)))
            m.source = url.lastPathComponent
            m.format = ["DOC", "DOCX"].contains(ext) ? "Word" : ext
            m.original = url
            return m
        }
        // Any other file (Keynote, Excel, design files…): use the system's Quick Look thumbnail as the cover
        var m = Material(kind: .document)
        m.title = name
        m.source = url.lastPathComponent
        m.format = ext.isEmpty ? "文件" : ext
        m.original = url
        m.images = await quickLookThumbnail(url).map { [$0] } ?? []
        return m
    }

    /// Image data: also recognizes animated and long images. Kept as-is, since animated images need the original file to move
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

    /// Text: a passage is collected as one of your text cards, editable later
    public static func text(_ raw: String) -> Material {
        var m = Material(kind: .text)
        m.form = .note
        m.text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(bodyLimit))
        return m
    }

    /// Whether a piece of text points to web pages or is content:
    /// - Every line is a URL (a list of links copied from Notes; without https:// counts too) → those URLs
    /// - Only one URL, the rest a short line (an app's share text like "【title】URL") → this URL, with the fetched title taking precedence
    /// - Anything else (links inside body text) → empty: the whole thing is collected as text, links inside aren't fetched
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

    /// The longest the non-URL part of share text can be: Douyin and Xiaohongshu share text carries a title and a line like "copy and open the app", about a hundred characters
    static let shareTextLimit = 140

    /// Web links in the text (https:// added when missing); emails and the like don't count
    private static func links(in text: String) -> [(url: URL, range: Range<String.Index>)] {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme), let range = Range(match.range, in: text) else { return nil }
            return (url, range)
        }
    }

    // MARK: File types

    /// Take a few frames from a video (positions as 0–1 fractions)
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

    /// PDF: page count, first-page thumbnail, body (read page by page, stopping when there's enough, so books of hundreds of pages don't stall)
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

    /// Uniform cleanup of extracted text: embedded-object placeholders (shown as boxes), control characters, piles of blank lines
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{FFFC}" && ($0.properties.generalCategory != .control || $0 == "\n") }))
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Image helpers

    /// The displayed width and height: phone photos are often stored sideways with a "rotate 90°" orientation tag, in which case width and height are swapped
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
