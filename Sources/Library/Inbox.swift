import Foundation

/// Inbox: a folder. Every entry point (dragging and pasting onto the canvas, the shortcut, the Services menu, the browser extension, the phone) first saves what it collects as a file here,
/// then says "collected"; the file is only deleted after the card is saved to the library. If the app quits or crashes midway, the file is still there and is collected again next time; already-saved ones are caught by the duplicate check.
/// Entry points on this Mac share one folder; the phone has another in iCloud, handled the same way, only the file format differs (read)
public actor Inbox {
    /// Where something collected from the canvas should land: which board (nil means library only) and which point in world coordinates
    public struct Spot: Codable, Sendable, Equatable {
        public var board: Int64?
        public var x: Double
        public var y: Double

        public init(board: Int64?, x: Double, y: Double) { (self.board, self.x, self.y) = (board, x, y) }
    }

    /// One collection: one or several files. id is the number the saving entry point assigned, used to reply when done; files with the same id were collected together
    public struct Arrival: Sendable {
        public var files: [URL]
        public var id: String?
        public var sources: [Source]
        public var spot: Spot?

        public init(file: URL, id: String? = nil, sources: [Source], spot: Spot? = nil) {
            (files, self.id, self.sources, self.spot) = ([file], id, sources, spot)
        }
    }

    /// Read a file; returns nil for files not meant for here or not readable yet (not fully written, not fully downloaded from iCloud), leaving them for next time
    public typealias Read = @Sendable (URL) -> Arrival?

    public nonisolated let folder: URL
    private let read: Read
    /// Files handed to collecting and not yet deleted: skipped when looking at the folder again, so nothing is collected twice
    private var collecting: Set<URL> = []

    public init(folder: URL, read: @escaping Read = Inbox.entry) {
        self.folder = folder
        self.read = read
    }

    /// What's not yet collected in the folder, in the order saved, grouped by collection, each handed to collect; whichever reports being saved to the library has its files deleted.
    /// One failing to save doesn't hold up the others
    public func drain(_ collect: @escaping @Sendable (Arrival) async -> Bool) async {
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
        // Regular files only: hidden files (temporary files mid-sync, .DS_Store) and subfolders are left alone
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? [])
            .map { $0.standardizedFileURL }
            .filter { !collecting.contains($0) }
            .compactMap { file in (try? file.resourceValues(forKeys: keys)).flatMap { $0.isRegularFile == true ? (file, $0.creationDate ?? .distantPast) : nil } }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
            .map(\.0)
        var arrivals: [Arrival] = []
        for one in files.compactMap(read) {
            if let id = one.id, let i = arrivals.firstIndex(where: { $0.id == id }) {
                arrivals[i].files += one.files
                arrivals[i].sources += one.sources
            } else {
                arrivals.append(one)
            }
        }
        collecting.formUnion(arrivals.flatMap(\.files))
        await withTaskGroup(of: (Arrival, Bool).self) { group in
            for arrival in arrivals { group.addTask { (arrival, await collect(arrival)) } }
            for await (arrival, saved) in group {
                if saved {
                    for file in arrival.files {
                        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: nil) { try? FileManager.default.removeItem(at: $0) }
                    }
                }
                collecting.subtract(arrival.files)
            }
        }
    }

    // MARK: Files in this Mac's inbox

    /// One file in this Mac's inbox: one JSON. The relay saves what the extension collects as-is (fields named like Wire's Message); what the app collects itself is saved by put
    struct Entry: Codable {
        var id: String?
        /// The collected URL; when it comes with html, image, imageURL or text, it's the page they're on
        var url: String?
        /// The rendered full page
        var html: String?
        var text: String?
        /// The image itself
        var image: Data?
        /// Only the image's address is known
        var imageURL: String?
        /// A file on your computer: only the path is recorded, the file itself is already on disk
        var file: String?
        /// The line that came with the URL
        var note: String?
        /// Collected from the canvas: where it should land
        var spot: Spot?

        /// Same priority as the extension's context menu: image, text, full page
        var source: Source? {
            let url = url.flatMap(URL.init(string:))
            if let file { return .file(URL(fileURLWithPath: file)) }
            if let image { return .image(image, page: url) }
            if let address = imageURL.flatMap(URL.init(string:)) { return .imageAt(address, page: url) }
            if let text {
                guard let url else { return .text(text) }
                // A passage selected on a web page: collected as a text card like pasted text, plus a source
                var m = FileExtractor.text(text)
                m.sourceURL = url.absoluteString
                m.source = url.host()
                return .ready(m)
            }
            guard let url else { return nil }
            if let html { return .rendered(RenderedPage(url: url, html: html)) }
            return note.map { .mentioned(url, in: $0) } ?? .url(url)
        }

        /// The kinds that can be collected from the clipboard, drag and drop, and the Services menu
        init?(_ source: Source, id: String, spot: Spot?) {
            (self.id, self.spot) = (id, spot)
            switch source {
            case .file(let url): file = url.path
            case .url(let address): url = address.absoluteString
            case .mentioned(let address, let words): (url, note) = (address.absoluteString, words)
            case .image(let data, let page): (image, url) = (data, page?.absoluteString)
            case .imageAt(let address, let page): (imageURL, url) = (address.absoluteString, page?.absoluteString)
            case .text(let words): text = words
            case .rendered, .ready: return nil
            }
        }
    }

    /// Read one file in this Mac's inbox. Only .json files that are fully written and renamed: saving writes to another name first
    public static let entry: Read = { file in
        guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), let source = entry.source else { return nil }
        return Arrival(file: file, id: entry.id, sources: [source], spot: entry.spot)
    }

    /// Save into this Mac's inbox, one file per thing, all with the same id; spot is where something collected from the canvas should land
    public func put(_ sources: [Source], id: String, spot: Spot? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in sources.compactMap({ Entry($0, id: id, spot: spot) }) {
            // The file name starts with the time in milliseconds, same as what the relay saves
            let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
            try JSONEncoder().encode(entry).write(to: folder.appending(path: name + ".part"))
            try FileManager.default.moveItem(at: folder.appending(path: name + ".part"), to: folder.appending(path: name + ".json"))
        }
    }
}
