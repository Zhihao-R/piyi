import CoreGraphics
import ImageIO
import Library
import Tokens

/// 每类卡片刚收进来时的尺寸（世界坐标）。之后的实际尺寸由画板里的摆放决定
public enum CardSize {
    /// 卡片最高显示到宽度的 1.7 倍；更长的图是长图，只露开头一截
    static let maxAspect = FileStore.maxAspect

    public static func initial(kind: Kind, coverAspect: CGFloat?, text: String?, hasBody: Bool) -> CGSize {
        let aspect = displayAspect(kind: kind, cover: coverAspect, text: text, hasBody: hasBody)
        let width = defaultWidth(kind, aspect: aspect)
        return CGSize(width: width, height: (width * aspect).rounded())
    }

    /// 高宽比，按内容决定
    static func displayAspect(kind: Kind, cover: CGFloat?, text: String?, hasBody: Bool) -> CGFloat {
        switch kind {
        case .image: min(cover ?? 1, maxAspect)
        case .text: textAspect(text ?? "")
        case .video: min(1.25, max(0.42, cover ?? 0.5625))
        case .document: cover.map { min(1.45, max(0.9, $0)) } ?? 1.3   // 一页纸
        case .web: cover.map { hasBody ? coverShare($0) + 0.8 : min(1.35, $0 + 0.34) } ?? (hasBody ? 0.85 : 0.62)   // 封面 + 正文或标题栏
        case .audio: 0.8
        }
    }

    /// 文章卡的封面高宽比：太扁、太高的封面裁掉多出的部分
    static let articleCover: ClosedRange<CGFloat> = 0.42...0.75
    static func coverShare(_ aspect: CGFloat) -> CGFloat { min(articleCover.upperBound, max(articleCover.lowerBound, aspect)) }

    /// 文字类卡片的字号、边距按这个宽度算，卡片拉多大都不变
    static let typeWidth: CGFloat = 240

    /// 新写的文字卡：默认宽度，三四行字的高度；写多了往下长
    static let note = CGSize(width: typeWidth, height: 120)

    /// 宽度是网格单位的整数倍：横图窄一些、竖图宽一些，看起来面积相近
    static func defaultWidth(_ kind: Kind, aspect: CGFloat) -> CGFloat {
        switch kind {
        case .image: aspect > 1.2 ? 200 : (aspect < 0.75 ? 300 : 260)
        case .video: 300
        case .text, .web, .document, .audio: typeWidth
        }
    }

    /// 短文按排版估算行数，刚好装下不缩字；长文是固定比例的竖版
    static func textAspect(_ text: String) -> CGFloat {
        guard text.count <= CardType.shortTextLimit else { return 1.3 }
        let cjk = CardArt.isCJK(text)
        let lines = ceil(Double(text.count) / (cjk ? CardType.quoteCharsPerLine.cjk : CardType.quoteCharsPerLine.latin))
        let font = cjk ? CardType.quoteCJK : CardType.quoteLatin
        let height = CardType.padding * 2 + CardType.footer * 1.6 + lines * (font * 1.25 + CardType.lineSpacing)
        return CGFloat(min(1.6, max(0.5, height)))
    }

    /// 封面的高宽比，读最小一档缩略图的文件头（不解码）
    public static func coverAspect(_ name: String, files: FileStore) -> CGFloat? {
        guard let src = CGImageSourceCreateWithURL(files.thumbnailURL(of: name, tier: FileStore.tiers[0]) as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? CGFloat, let h = p[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 else { return nil }
        return h / w
    }
}
