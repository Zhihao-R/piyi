// 画图标：深色底上两张错开的浅色卡片。App 图标和浏览器扩展图标是同一张画。
// 运行：swift scripts/icons.swift（在仓库根目录）
// App 图标是 Icon Composer 格式（AppIcon.icon）：底色写在 icon.json 里，两张卡各画成一层，系统按层加玻璃质感，打包时由 actool 编译；
// 扩展图标是画好底色的整张 PNG。
import AppKit

let ink = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1)
let paper = (r: 0.985, g: 0.982, b: 0.972)
// 两张卡：后面那张淡一些、往左歪，前面那张卡片底色、往右歪。位置、大小按图标边长的比例
let back = (center: CGPoint(x: 0.39, y: 0.55), angle: 9.0, alpha: 0.45)
let front = (center: CGPoint(x: 0.60, y: 0.45), angle: -7.0, alpha: 1.0)

func png(_ size: Int, to url: URL, draw: (CGContext, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext, CGFloat(size))
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func card(_ ctx: CGContext, _ s: CGFloat, _ center: CGPoint, _ angle: Double, _ alpha: Double) {
    ctx.saveGState()
    ctx.translateBy(x: center.x * s, y: center.y * s)
    ctx.rotate(by: angle * .pi / 180)
    let w = s * 0.38, h = s * 0.46
    ctx.addPath(CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: paper.r, green: paper.g, blue: paper.b, alpha: alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

// App 图标的两层：整块画布 1024 点，系统自己裁成圆角方形
let layers = URL(fileURLWithPath: "Resources/AppIcon.icon/Assets")
try! FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
png(1024, to: layers.appending(path: "back.png")) { ctx, s in card(ctx, s, back.center, back.angle, back.alpha) }
png(1024, to: layers.appending(path: "front.png")) { ctx, s in card(ctx, s, front.center, front.angle, front.alpha) }

// 扩展图标：自己画圆角底
for size in [16, 32, 48, 128] {
    png(size, to: URL(fileURLWithPath: "Extension/static/icons/\(size).png")) { ctx, s in
        let inset = s * 0.03
        ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                           cornerWidth: s * 0.24, cornerHeight: s * 0.24, transform: nil))
        ctx.setFillColor(ink)
        ctx.fillPath()
        card(ctx, s, back.center, back.angle, back.alpha)
        card(ctx, s, front.center, front.angle, front.alpha)
    }
}
