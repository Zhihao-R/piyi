import Foundation
import Library

/// Sample data bundled with the App
enum Seed {
    private struct Item: Decodable {
        /// image (museum image), quote (quotation), link (link with a pre-downloaded cover), file (sample file), url (handed to web extraction)
        var kind: String
        var file: String?
        var text: String?
        var title: String?
        var source: String?
        var url: String?
        var createdAt: Double
        /// Placement on the sample board: top-left corner, width and height (world coordinates) and rotation (degrees). Height computed from the card's own ratio if not given; laid out automatically if neither is given
        var x: Double?
        var y: Double?
        var width: Double?
        var height: Double?
        var rotation: Double?
        /// Versions swapped in for other interface languages, by language code (en): quotes, quick notes, Chinese files
        var variants: [String: Variant]?
        /// Pre-generated understanding results, one per language code (zh, en): new users opening the sample board don't need to call the model
        var understood: [String: Understood]?
    }

    private struct Understood: Decodable {
        var title: String
        var caption: String
        var detail: String?
        var tags: [String]
        var summary: String?
        var anchors: [SummaryAnchor?]?
    }

    private struct Variant: Decodable {
        var text: String?
        var source: String?
        var file: String?
    }

    /// What's fixed in advance for a sample card: where it goes, how it's understood
    struct Preset: Sendable {
        var spot: Spot?
        var understood: Generated?
    }

    /// A sample card's position on the board
    struct Spot: Sendable {
        var origin: CGPoint
        var width: CGFloat
        var height: CGFloat?
        /// Radians
        var rotation: CGFloat
    }

    /// Packaged as .app, the resource bundle is in Contents/Resources; under swift run it's in the build directory
    static var directory: URL? {
        let name = "Piyi_Piyi.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appending(path: name)), let url = bundle.url(forResource: "Seed", withExtension: nil) { return url }
        }
        return nil
    }

    private static var items: [Item] {
        guard let dir = directory, let data = try? Data(contentsOf: dir.appending(path: "manifest.json")) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    /// Samples for new users: they go through the same collection flow as things you drag in, each with its pre-set position and understanding result
    static func sources() -> [(source: Source, preset: Preset)] {
        guard let dir = directory else { return [] }
        return items.compactMap { original in
            var item = original
            if let variant = item.variants?[interfaceLanguage] {
                item.text = variant.text ?? item.text
                item.source = variant.source ?? item.source
                item.file = variant.file ?? item.file
                // Cards with replaced text get their height recomputed from the translation's length
                if variant.text != nil { item.height = nil }
            }
            let understood = item.understood?[interfaceLanguage].map {
                Generated(title: $0.title, caption: $0.caption, detail: $0.detail, tags: $0.tags, summary: $0.summary, anchors: $0.anchors)
            }
            return source(item, in: dir).map { ($0, Preset(spot: spot(item), understood: understood)) }
        }
    }

    private static func spot(_ item: Item) -> Spot? {
        guard let x = item.x, let y = item.y, let width = item.width else { return nil }
        return Spot(origin: CGPoint(x: x, y: y), width: width, height: item.height.map { CGFloat($0) }, rotation: (item.rotation ?? 0) * .pi / 180)
    }

    private static func source(_ item: Item, in dir: URL) -> Source? {
        switch item.kind {
        case "image":
            guard let file = item.file, let data = try? Data(contentsOf: dir.appending(path: "images/" + file)) else { return nil }
            // The museum's original name goes into the source, leaving the title for understanding to write in the interface language
            var m = FileExtractor.image(data)
            m.source = [item.title, item.source].compactMap { $0 }.joined(separator: " · ")
            m.sourceURL = item.url
            return .ready(m)
        case "quote":
            var m = FileExtractor.text(item.text ?? "")
            m.source = item.source
            return .ready(m)
        case "link":
            var m = Material(kind: .web)
            m.title = item.title
            m.source = item.source
            m.url = item.url
            m.images = [item.file.flatMap { try? Data(contentsOf: dir.appending(path: "images/" + $0)) }].compactMap { $0 }
            return .ready(m)
        case "file":
            return item.file.map { .file(dir.appending(path: "files/" + $0)) }
        case "url":
            return item.url.flatMap(URL.init(string:)).map(Source.url)
        default:
            return nil
        }
    }

    /// Which board is the "Sample" board, used when existing libraries turn off its automatic sorting once
    static var board: Int64? {
        get { UserDefaults.standard.object(forKey: "sampleBoard") as? Int64 }
        set { UserDefaults.standard.set(newValue, forKey: "sampleBoard") }
    }

    /// Sample boards created before automatic sorting existed have already had automatic sorting turned off once
    static var sortingClosed: Bool {
        get { UserDefaults.standard.bool(forKey: "sampleSortingClosed") }
        set { UserDefaults.standard.set(newValue, forKey: "sampleSortingClosed") }
    }
}
