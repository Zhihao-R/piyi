import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Library
import Tokens

/// 画板入口的缩略拼贴：把整个画板缩小画成一张图。图片卡画封面的最小一档，其余的卡画成一块卡片底色
public enum BoardCollage {
    /// 在后台读出画板、画好、存起来
    public static func refresh(_ board: Int64, store: Store) async throws {
        let items = try await store.items(on: board)
        guard let jpeg = await render(items, files: store.files) else { return }
        try await store.setCollage(board, jpeg: jpeg)
    }

    @concurrent static func render(_ items: [BoardItem], files: FileStore, width: CGFloat = 480) async -> Data? {
        let bounds = items.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let k = width / bounds.width
        let height = min(bounds.height * k, width * 1.5)
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let pen = Pen(ctx: ctx, size: CGSize(width: width, height: height), pixelScale: 1)
        pen.fill(Palette.canvas.light)
        for item in items.sorted(by: { $0.placement.z < $1.placement.z }) {
            let f = item.placement.frame
            let r = CGRect(x: (f.minX - bounds.minX) * k, y: (f.minY - bounds.minY) * k, width: f.width * k, height: f.height * k)
            guard r.minY < height else { continue }
            if case .card(let card) = item.face, let cover = card.cover,
               let src = CGImageSourceCreateWithURL(files.thumbnailURL(of: cover, tier: FileStore.tiers[0]) as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                pen.image(image, in: r)
            } else {
                pen.rect(r, Palette.card.light)
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
