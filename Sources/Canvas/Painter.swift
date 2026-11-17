import Foundation
import CoreGraphics
import ImageIO
import Library

/// Draws a card into a bitmap in the background: reads the cover thumbnail by size tier (only the cropped part if cropped), then draws it together with the text and badges as one image.
/// Requests follow the caller's Task: cancelled when the card leaves the view, and skipped outright if they haven't started yet.
@MainActor
enum Painter {
    static func bitmap(for item: BoardItem, scale: CGFloat, files: FileStore) async -> CGImage? {
        await paint(item, scale: scale, files: files)
    }

    /// Draws on a background thread, off the main thread; priority follows the caller (userInitiated for cards in view)
    @concurrent private nonisolated static func paint(_ item: BoardItem, scale: CGFloat, files: FileStore) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let size = item.placement.frame.size
        let pixels = resolution(item, scale: scale)
        var cover: CGImage?
        if let name = coverName(item.face) {
            let crop = item.placement.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            cover = decode(name, width: pixels / crop.width, long: item.isLong, files: files).flatMap { cropped($0, to: crop) }
            guard !Task.isCancelled else { return nil }
        }
        return CardArt(face: item.face, size: size, cover: cover, zoom: item.zoom, unseen: item.placement.unseen).render(pixelScale: pixels / size.width)
    }

    /// A transparent image with only the badges (see CardArt.marksOnly), drawn in the background
    @concurrent nonisolated static func marks(for item: BoardItem, scale: CGFloat) async -> CGImage? {
        let size = item.placement.frame.size
        return CardArt(face: item.face, size: size, cover: nil, zoom: item.zoom, unseen: item.placement.unseen, marksOnly: true)
            .render(pixelScale: resolution(item, scale: scale) / size.width)
    }

    /// How many pixels wide to draw this card at a given scale: cards with a cover round to a thumbnail tier (redraw only when the tier changes); text-only cards draw at most 2x
    nonisolated static func resolution(_ item: BoardItem, scale: CGFloat) -> CGFloat {
        let width = item.placement.width
        guard coverName(item.face) != nil else { return width * min(scale, 2) * Screen.scale }
        let crop = item.placement.crop?.width ?? 1
        let pixels = width * scale * Screen.scale
        return tier(pixels / crop).map { CGFloat($0) * crop } ?? pixels
    }

    /// Whether to redraw at the new scale once things settle: when the pixel width to draw changes by more than 25%
    static func isStale(_ item: BoardItem, renderedAt old: CGFloat, for new: CGFloat) -> Bool {
        !(0.8...1.25).contains(resolution(item, scale: new) / resolution(item, scale: old))
    }

    private nonisolated static func coverName(_ face: Face) -> String? {
        switch face {
        case .card(let card): card.cover
        case .entry(_, _, let collage): collage
        }
    }

    /// The smallest tier that fits this many pixels wide; when even 1024 isn't enough, use the original (nil)
    nonisolated static func tier(_ pixels: CGFloat) -> Int? { FileStore.tiers.first { CGFloat($0) >= pixels } }

    /// Reads a thumbnail by tier; if this tier isn't generated yet, falls back to a smaller one. When even 1024 isn't enough, decodes from the original at the needed width; long images only take the visible part (same as the thumbnails)
    private nonisolated static func decode(_ cover: String, width: CGFloat, long: Bool, files: FileStore) -> CGImage? {
        if let wanted = tier(width) {
            for t in FileStore.tiers.filter({ $0 <= wanted }).reversed() {
                if let image = load(files.thumbnailURL(of: cover, tier: t), maxPixel: nil) { return image }
            }
        }
        guard let image = load(files.url(of: cover), maxPixel: width) else { return nil }
        let top = CGFloat(image.width) * FileStore.maxAspect
        return long && CGFloat(image.height) > top ? image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: top.rounded())) : image
    }

    /// Crop frame normalized to the original's width and height, origin at top left
    private nonisolated static func cropped(_ image: CGImage, to crop: CGRect) -> CGImage? {
        guard crop != CGRect(x: 0, y: 0, width: 1, height: 1) else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return image.cropping(to: CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h).integral)
    }

    private nonisolated static func load(_ url: URL, maxPixel: CGFloat?) -> CGImage? {
        guard !Task.isCancelled, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let maxPixel, let size = FileExtractor.pixelSize(src) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * min(1, maxPixel / size.width)]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// A bitmap the GPU can use directly: screen color space, BGRA, premultiplied alpha. Handed to the layer once drawn, so committing on the main thread is just a copy
func screenBitmap(width: Int, height: Int) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                     space: Screen.colorSpace,
                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
}
