import Foundation
import CoreGraphics
import ImageIO
import Library

/// 在后台把一张卡画成位图：封面按档位读缩略图（裁剪过的只取那一块），再和文字、角标一起画成一张图。
/// 请求跟随调用方的 Task：卡片离开视野时取消，还没开始的就直接跳过。
@MainActor
enum Painter {
    static func bitmap(for item: BoardItem, scale: CGFloat, files: FileStore) async -> CGImage? {
        await paint(item, scale: scale, files: files)
    }

    /// 在后台线程上画，不占主线程；优先级跟随调用方（视野内的卡用 userInitiated）
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

    /// 这张卡在给定倍率下要画多少像素宽：有封面的按缩略图档位取整（换档才重画），纯文字的最多画到 2 倍
    nonisolated static func resolution(_ item: BoardItem, scale: CGFloat) -> CGFloat {
        let width = item.placement.width
        guard coverName(item.face) != nil else { return width * min(scale, 2) * Screen.scale }
        let crop = item.placement.crop?.width ?? 1
        let pixels = width * scale * Screen.scale
        return tier(pixels / crop).map { CGFloat($0) * crop } ?? pixels
    }

    /// 停手后要不要按新倍率重画：要画的像素宽变化超过 25%
    static func isStale(_ item: BoardItem, renderedAt old: CGFloat, for new: CGFloat) -> Bool {
        !(0.8...1.25).contains(resolution(item, scale: new) / resolution(item, scale: old))
    }

    private nonisolated static func coverName(_ face: Face) -> String? {
        switch face {
        case .card(let card): card.cover
        case .entry(_, _, let collage): collage
        }
    }

    /// 放得下这么多像素宽的最小一档；1024 也不够时用原图（nil）
    nonisolated static func tier(_ pixels: CGFloat) -> Int? { FileStore.tiers.first { CGFloat($0) >= pixels } }

    /// 按档位读缩略图；这一档还没生成就退到小一档。1024 也不够时按需要的宽度从原图解码，长图只取露出的那一截（和缩略图一致）
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

    /// 裁剪框按原图宽高归一，左上为原点
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

/// 显卡直接能用的位图：屏幕颜色空间、BGRA、预乘透明度。画好交给图层，主线程提交时只剩拷贝
func screenBitmap(width: Int, height: Int) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                     space: Screen.colorSpace,
                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
}
