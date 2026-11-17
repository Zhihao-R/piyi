import Foundation
import CoreGraphics
import GRDB

/// Cards fall into six kinds by what the content looks like, not by source: a local mp4 and a Bilibili video are both video
public enum Kind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case image, text, web, document, video, audio
}

/// Forms within one kind that need different handling
public enum Form: String, Codable, Sendable, DatabaseValueConvertible {
    /// Long image: the card shows only the top part
    case long
    /// Animated image: moves only on hover
    case animated
    /// Your text: plain text written on a board, pasted, or collected from the phone. Editable, can change background color.
    /// Text-only web posts (with a URL) are someone else's words and don't count
    case note
}

/// How far extraction has got
public enum Extraction: String, Codable, Sendable, DatabaseValueConvertible {
    case extracting
    /// Extraction finished. If only part was fetched, partial records why
    case complete
}

/// How far understanding is queued; nil means nothing to do
public enum Understanding: String, Codable, Sendable, DatabaseValueConvertible {
    /// Needs a title and description: the card's look is about to change, so the canvas marks it "Reading"
    case generating
    /// Only filling in colors and vectors: the look doesn't change, only counted in the status bar
    case indexing
    /// Needs a title and description, but no key yet (or the key was rejected). Colors and vectors are computed as usual
    case waitingKey
}

/// One record in the library: original content + understanding results
public struct Card: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var kind: Kind
    public var form: Form?
    /// When it was first collected: unchanged by collecting again; used for grouping by day and filtering by time
    public var collectedAt: Date
    /// When it was last collected again: "All Cards" brings it to the front by this; nil if never collected again
    public var resurfacedAt: Date?

    // Original content
    /// Recorded here when the collected thing is this URL itself (web cards, direct file links); used for refetching
    public var url: String?
    /// URL for comparison: the URL duplicate check looks at it and finalKey
    public var urlKey: String?
    /// When the collected URL redirected elsewhere (a short link), the comparison URL of the final address: so collecting the long link later finds this card too
    public var finalKey: String?
    /// Source URL: the page a dragged-in image was on, or the final page the collected URL redirected to. Not used in duplicate checks
    public var sourceURL: String?
    /// Content fingerprint: the content duplicate check only looks at this
    public var fingerprint: String?
    public var title: String?
    /// Source: author, site, file name
    public var source: String?
    /// Format label for people: PDF, Markdown, GIF, Xiaohongshu, Bilibili…
    public var format: String?
    /// Text you wrote yourself
    public var text: String?
    /// The line that came with the URL when collected ("reference the layout of figma.com's pricing page"); refetching doesn't touch it
    public var note: String?
    /// Background color name of a text card you wrote (see Palette.tints); nil is the card's default background
    public var tint: String?
    /// Extracted body; for video it's the description
    public var body: String?
    /// What a video or audio says (local transcription, or platform subtitles), format in Transcript. Without it the summary only goes by the description
    public var transcript: String?
    /// Body completion (text recognition in images, transcription, platform subtitles) is done. Sorting waits for it
    public var bodyCompleted: Bool
    /// Cover and original file: file names in the file store (content fingerprint + extension)
    public var cover: String?
    public var original: String?
    /// Address for playing an online video in the detail view: the platform's embed player, or a video stream (see Player). Videos aren't downloaded, so there's no original
    public var player: String?
    public var pages: Int?
    /// Seconds
    public var duration: Double?
    public var extraction: Extraction
    /// Why only part was fetched; nil means complete
    public var partial: Partial?
    /// When it was trashed; nil means not deleted
    public var trashedAt: Date?

    // Understanding results
    public var generatedTitle: String?
    /// The one-line text shown on the card
    public var caption: String?
    /// Not shown, a long description only used to compute vectors
    public var detail: String?
    public var tags: [String]
    public var summary: String?
    /// The original passage each key point is based on, see SummaryAnchor
    public var summaryAnchors: [SummaryAnchor?]?
    /// Color statistics; the format is up to understanding, the library module only stores it
    public var colors: String?
    /// Digest of the content the title, description, tags and summary were generated from; when the basis changes it's re-queued
    public var understoodBasis: String?
    public var understandError: String?
    public var understanding: Understanding?
    /// Sorted: whether or not it was put on another board, once sorted it's never auto-sorted again
    public var sorted: Bool

    public init(kind: Kind, collectedAt: Date = .now) {
        self.kind = kind
        self.collectedAt = collectedAt
        self.extraction = .extracting
        self.bodyCompleted = false
        self.tags = []
        self.sorted = false
    }

    public static let databaseTableName = "card"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Title for display: web pages, documents and videos keep their original title, images and text use the model's (their original title is usually a file name).
    /// The canvas reads the SQL version of the same rule in CardFace.columns; change both together
    public var displayTitle: String {
        let preferred = kind == .image || kind == .text ? generatedTitle ?? title : title ?? generatedTitle
        return preferred ?? text.map { String($0.prefix(16)) } ?? ""
    }

    /// Got content: at least one of cover, body, transcript, text
    public var hasContent: Bool { cover != nil || body != nil || transcript != nil || text != nil }

    /// A partial card with no content: the title is just the URL or a failure page's title, not content to understand
    public var isEmpty: Bool { partial != nil && !hasContent }

    /// The full body: body followed by transcript. Understanding and search read it
    public var fullBody: String? {
        let parts = [body, transcript].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Basis for understanding: only understanding's inputs (original title, body, your text, cover), not what understanding wrote itself, or it would keep re-queuing
    public var contentBasis: String { Self.basis(title: title, body: fullBody, text: text, cover: cover) }

    static func basis(title: String?, body: String?, text: String?, cover: String?) -> String {
        FileStore.fingerprint(Data([title, body, text, cover].map { $0 ?? "" }.joined(separator: "\u{1F}").utf8))
    }
}

/// The other images of a multi-image card, in order
public struct CardImage: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public var cardID: Int64
    public var position: Int
    public var file: String

    public static let databaseTableName = "cardImage"
}

/// Each card's vector, noting which model and which text it was computed from
public struct Vector: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var cardID: Int64
    public var model: String
    public var basis: String
    public var data: Data

    public init(cardID: Int64, model: String, basis: String, values: [Float]) {
        self.cardID = cardID
        self.model = model
        self.basis = basis
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static let databaseTableName = "vector"
}

public struct Board: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    /// Thumbnail collage: file name in the thumbnails folder
    public var collage: String?
    public var createdAt: Date
    public var openedAt: Date
    /// Auto-sort: when off, this board no longer receives cards automatically
    public var autoSort = true
    /// Sorting rule: one sentence on what this board collects; nil means not written, judge by the cards already on the board
    public var rule: String?

    public init(name: String, at date: Date = .now) {
        self.name = name
        self.createdAt = date
        self.openedAt = date
    }

    public static let databaseTableName = "board"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// How a card or a board entry is placed on a board. Exactly one of cardID and entryBoardID is set
public struct Placement: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var boardID: Int64
    public var cardID: Int64?
    /// The board a board entry points to
    public var entryBoardID: Int64?
    /// World coordinates, origin at the top left, y pointing down
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Radians
    public var rotation: Double
    /// Mirroring: flipped when a corner is dragged past the opposite corner (mirror first, then rotate)
    public var flipX = false
    public var flipY = false
    /// Crop rect: a region of the original image, normalized to 0–1 by its width and height; nil means no crop
    public var crop: CGRect?
    /// Stacking order, larger on top
    public var z: Double
    /// Newly-placed mark: put here by sorting and you haven't seen it yet. Cleared when you leave this board
    public var unseen = false

    public init(boardID: Int64, cardID: Int64? = nil, entryBoardID: Int64? = nil, frame: CGRect, z: Double) {
        self.boardID = boardID
        self.cardID = cardID
        self.entryBoardID = entryBoardID
        (x, y, width, height) = (frame.minX, frame.minY, frame.width, frame.height)
        rotation = 0
        self.z = z
    }

    public var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { (x, y, width, height) = (newValue.minX, newValue.minY, newValue.width, newValue.height) }
    }

    public static let databaseTableName = "placement"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Setting: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var key: String
    public var value: String

    public static let databaseTableName = "setting"
}
