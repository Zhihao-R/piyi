// 画扩展图标：深色圆角底上两张错开的浅色卡片。运行：swift Extension/tools/icons.swift Extension/static/icons
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 48, 128] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // 底：和卡片文字同一种墨色
    let inset = s * 0.03
    ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                       cornerWidth: s * 0.24, cornerHeight: s * 0.24, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1))
    ctx.fillPath()
    // 两张卡：后面那张淡一些、往左歪，前面那张卡片底色、往右歪
    func card(_ center: CGPoint, _ angle: CGFloat, _ alpha: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x * s, y: center.y * s)
        ctx.rotate(by: angle * .pi / 180)
        let w = s * 0.38, h = s * 0.46
        ctx.addPath(CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.985, green: 0.982, blue: 0.972, alpha: alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }
    card(CGPoint(x: 0.39, y: 0.55), 9, 0.45)
    card(CGPoint(x: 0.60, y: 0.45), -7, 1)
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: "\(size).png"))
}
