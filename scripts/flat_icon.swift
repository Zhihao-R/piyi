// Fallback App icon without Xcode (actool): stacks the background color and two card layers of AppIcon.icon into one image, converted to a plain AppIcon.icns, without the glass effect
// Run: swift scripts/flat_icon.swift <output .icns path> (from the repo root; build_app.sh calls it automatically)
import AppKit

let source = URL(fileURLWithPath: "Resources/AppIcon.icon")
let output = URL(fileURLWithPath: CommandLine.arguments[1])

// The background color is read from icon.json, matching the Icon Composer setting, e.g. "srgb:0.11000,0.11000,0.10000,1.00000"
let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: source.appending(path: "icon.json"))) as! [String: Any]
let solid = (json["fill"] as! [String: Any])["solid"] as! String
let rgba = solid.split(separator: ":")[1].split(separator: ",").map { CGFloat(Double($0)!) }
let fill = CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])

// Layers are listed top to bottom in icon.json, and drawn bottom to top
let groups = json["groups"] as! [[String: Any]]
let layerNames = groups.flatMap { ($0["layers"] as! [[String: Any]]).map { $0["image-name"] as! String } }.reversed()
let layers = layerNames.map { NSImage(contentsOf: source.appending(path: "Assets/\($0)"))! }

// macOS icon grid: on a 1024 canvas, the rounded square takes 824 with 100 around it; layers fill that rounded square
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(size) / 1024
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil))
    ctx.clip()
    ctx.setFillColor(fill)
    ctx.fill(body)
    for layer in layers { layer.draw(in: body) }
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
