// Draws the icons: two offset light cards on a dark background. The App icon and the browser extension icon are the same drawing.
// Run: swift scripts/icons.swift (from the repo root)
// The App icon is in Icon Composer format (AppIcon.icon): the background color is in icon.json, each card is drawn as its own layer, the system adds the glass effect per layer, and actool compiles it at packaging time;
// the extension icons are complete PNGs with the background drawn in.
import AppKit

let ink = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.10, alpha: 1)
let paper = (r: 0.985, g: 0.982, b: 0.972)
// Two cards: the back one fainter and tilted left, the front one in card color and tilted right. Positions and sizes are proportional to the icon's side length
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

// The App icon's two layers: the whole canvas is 1024 points, and the system crops it into a rounded square itself
let layers = URL(fileURLWithPath: "Resources/AppIcon.icon/Assets")
try! FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
png(1024, to: layers.appending(path: "back.png")) { ctx, s in card(ctx, s, back.center, back.angle, back.alpha) }
png(1024, to: layers.appending(path: "front.png")) { ctx, s in card(ctx, s, front.center, front.angle, front.alpha) }

// Extension icons: draw the rounded background ourselves
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
