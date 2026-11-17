import Foundation
import CoreGraphics

/// One thing handed over by a collecting entry point
public enum Source: Sendable {
    case file(URL)
    case url(URL)
    /// An image dragged from the browser: the image itself + the URL of the page it's on
    case image(Data, page: URL?)
    /// An image on a web page with only its address known (the extension didn't get the image itself): download it, recording the page it's on as the source
    case imageAt(URL, page: URL?)
    /// A URL inside a sentence: collect this URL, record the sentence on the card
    case mentioned(URL, in: String)
    case text(String)
    /// "Collect to Piyi" was clicked in the browser: the page is already rendered
    case rendered(RenderedPage)
    /// Already extracted (link cards pre-downloaded in the sample data)
    case ready(Material)

    /// Guess a kind before extracting, for the placeholder card
    public var kind: Kind {
        switch self {
        case .file(let url): FileExtractor.kind(of: url)
        case .url, .rendered, .mentioned: .web
        case .image, .imageAt: .image
        case .text: .text
        case .ready(let m): m.kind
        }
    }

    /// The collected thing is this URL itself (for the URL duplicate check)
    public var url: URL? {
        switch self {
        case .url(let url), .imageAt(let url, _), .mentioned(let url, _): url
        case .rendered(let page): page.url
        case .ready(let m): m.url.flatMap(URL.init(string:))
        default: nil
        }
    }

    /// The URL of the page it's on, recorded as the source
    public var page: URL? {
        switch self {
        case .image(_, let page), .imageAt(_, let page): page
        default: nil
        }
    }

    /// The line that came with the URL
    public var note: String? { if case .mentioned(_, let words) = self { words } else { nil } }
}

/// The single entry point for content extraction: any source → material
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

    /// An image found on a web page: record the page it's on as the source
    private static func found(_ image: Material, on page: URL?) -> Material {
        guard let page else { return image }
        var m = image
        m.sourceURL = page.absoluteString
        m.source = page.host()
        return m
    }
}

extension Extractor {
    /// Body completion: the last step of extraction, done in the background at lower priority; the results are searchable and readable like the rest of the body. Recorded on the card when done; sorting waits for it.
    /// Image cards and scanned PDFs (pages but no body) get text recognized from the images, appended to the body; video and audio with a file are transcribed locally,
    /// platform videos aren't downloaded, so platform subtitles are fetched and stored separately as the transcript
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
        // Don't transcribe the same content again. A refetch replaces the body, and it's fetched again then
        if card.kind == .video || card.kind == .audio, card.transcript == nil {
            var cues: [Cue]?
            if let original = card.original {
                cues = await models?.transcribe(store.files.url(of: original))
            } else if let url = card.url.flatMap(URL.init(string:)) {
                cues = await web.subtitles(for: url)
            }
            if let cues { try await store.setTranscript(id, String(Transcript.text(cues).prefix(FileExtractor.bodyLimit))) }
        }
        // Failing to transcribe still counts as done: sorting stops waiting for it
        try await store.markBodyCompleted(id)
    }
}
