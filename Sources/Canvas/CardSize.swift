import CoreGraphics
import ImageIO
import Library
import Tokens

/// Size of each kind of card when first collected (world coordinates). Its actual size afterwards is set by how it's placed on the board
public enum CardSize {
    /// Cards show at most 1.7 times their width in height; longer images are long images and only show the top part
    static let maxAspect = FileStore.maxAspect

    public static func initial(kind: Kind, coverAspect: CGFloat?, text: String?, hasBody: Bool) -> CGSize {
        let aspect = displayAspect(kind: kind, cover: coverAspect, text: text, hasBody: hasBody)
        let width = defaultWidth(kind, aspect: aspect)
        return CGSize(width: width, height: (width * aspect).rounded())
    }

    /// Height-to-width ratio, decided by the content
    static func displayAspect(kind: Kind, cover: CGFloat?, text: String?, hasBody: Bool) -> CGFloat {
        switch kind {
        case .image: min(cover ?? 1, maxAspect)
        case .text: textAspect(text ?? "")
        case .video: min(1.25, max(0.42, cover ?? 0.5625))
        case .document: cover.map { min(1.45, max(0.9, $0)) } ?? 1.3   // A page of paper
        case .web: cover.map { hasBody ? coverShare($0) + 0.8 : min(1.35, $0 + 0.34) } ?? (hasBody ? 0.85 : 0.62)   // Cover + body or title bar
        case .audio: 0.8
        }
    }

    /// Cover aspect ratio for article cards: covers that are too flat or too tall get the excess cropped
    static let articleCover: ClosedRange<CGFloat> = 0.42...0.75
    static func coverShare(_ aspect: CGFloat) -> CGFloat { min(articleCover.upperBound, max(articleCover.lowerBound, aspect)) }

    /// Font size and margins of text cards are computed against this width, so they stay the same however large the card is stretched
    static let typeWidth: CGFloat = 240

    /// A newly written text card: default width, about three or four lines tall; grows downward as you write more
    static let note = CGSize(width: typeWidth, height: 120)

    /// Width is a whole multiple of the grid unit: landscape images a bit narrower, portrait ones a bit wider, so they look about the same area
    static func defaultWidth(_ kind: Kind, aspect: CGFloat) -> CGFloat {
        switch kind {
        case .image: aspect > 1.2 ? 200 : (aspect < 0.75 ? 300 : 260)
        case .video: 300
        case .text, .web, .document, .audio: typeWidth
        }
    }

    /// Short text: estimate the line count by layout so it just fits without shrinking the font; long text is portrait at a fixed ratio
    static func textAspect(_ text: String) -> CGFloat {
        guard text.count <= CardType.shortTextLimit else { return 1.3 }
        let cjk = CardArt.isCJK(text)
        let lines = ceil(Double(text.count) / (cjk ? CardType.quoteCharsPerLine.cjk : CardType.quoteCharsPerLine.latin))
        let font = cjk ? CardType.quoteCJK : CardType.quoteLatin
        let height = CardType.padding * 2 + CardType.footer * 1.6 + lines * (font * 1.25 + CardType.lineSpacing)
        return CGFloat(min(1.6, max(0.5, height)))
    }

    /// The cover's aspect ratio, read from the file header of the smallest thumbnail (without decoding)
    public static func coverAspect(_ name: String, files: FileStore) -> CGFloat? {
        guard let src = CGImageSourceCreateWithURL(files.thumbnailURL(of: name, tier: FileStore.tiers[0]) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 else { return nil }
        return h / w
    }
}
