import Foundation
import CoreGraphics
import ImageIO
import simd

/// 12 nameable colors. 「绿色」 (green) and "white" in search map to these
public enum ColorName: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, pink, brown, black, white, gray
}

/// Color stats: each color's share of the image, and a few dominant colors by area. Stored in the card's colors field
public struct ColorProfile: Codable, Equatable, Sendable {
    /// 0～1
    public var share: [ColorName: Float]
    /// Hex, by area from largest to smallest
    public var swatches: [String]
}

extension ColorProfile {
    /// Read back what's stored in the card's colors field
    public init?(json: String) {
        guard let profile = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = profile
    }

    /// What color it looks like at a glance: the most common chromatic color, counted only at 15% or more; otherwise the most common of black, white and gray. Used to group the library by color
    public var main: ColorName? {
        let neutral: Set<ColorName> = [.black, .white, .gray]
        if let hue = share.filter({ !neutral.contains($0.key) }).max(by: { $0.value < $1.value }), hue.value >= 0.15 { return hue.key }
        return share.max { $0.value < $1.value }?.key
    }
}

/// Colors computed from pixels, without a model: deterministic, done in milliseconds
enum ColorAnalysis {
    /// How it's written into the card's colors field
    static func json(ofImageAt url: URL) -> String? {
        profile(ofImageAt: url).flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }

    static func profile(ofImageAt url: URL) -> ColorProfile? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) else { return nil }
        return profile(of: image)
    }

    static func profile(of image: CGImage) -> ColorProfile? {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var counts: [ColorName: Int] = [:]
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(side * side)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
            samples.append(rgb)
            counts[classify(rgb), default: 0] += 1
        }
        let total = Float(samples.count)
        return ColorProfile(share: counts.mapValues { Float($0) / total }, swatches: dominant(samples, k: 5).map(hex))
    }

    /// Assign a pixel to a color by hue, saturation and brightness
    static func classify(_ c: SIMD3<Float>) -> ColorName {
        let maxC = max(c.x, c.y, c.z), minC = min(c.x, c.y, c.z)
        let v = maxC, d = maxC - minC
        let s = maxC == 0 ? 0 : d / maxC
        if v < 0.2 { return .black }
        if s < 0.22 && v > 0.8 { return .white }          // Off-white and old paper count as white too
        if s < 0.14 || d < 0.07 { return v < 0.35 ? .black : .gray }
        var h: Float
        if maxC == c.x { h = (c.y - c.z) / d } else if maxC == c.y { h = 2 + (c.z - c.x) / d } else { h = 4 + (c.x - c.y) / d }
        h = (h * 60).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        switch h {
        case ..<14, 345...: return v < 0.45 ? .brown : (v > 0.75 && s < 0.5 ? .pink : .red)
        case 14..<42: return v < 0.6 ? .brown : .orange
        case 42..<68: return v < 0.45 ? .brown : .yellow
        case 68..<165: return .green
        case 165..<195: return .cyan
        case 195..<255: return .blue
        case 255..<290: return .purple
        default: return v < 0.45 ? .purple : .pink
        }
    }

    /// Simple k-means for dominant colors
    private static func dominant(_ samples: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        guard samples.count >= k else { return samples }
        var centers = (0..<k).map { samples[$0 * samples.count / k] }
        var assignment = [Int](repeating: 0, count: samples.count)
        for _ in 0..<8 {
            for (i, p) in samples.enumerated() {
                assignment[i] = (0..<k).min { simd_length_squared(centers[$0] - p) < simd_length_squared(centers[$1] - p) }!
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: k), n = [Float](repeating: 0, count: k)
            for (i, p) in samples.enumerated() { sums[assignment[i]] += p; n[assignment[i]] += 1 }
            for j in 0..<k where n[j] > 0 { centers[j] = sums[j] / n[j] }
        }
        var n = [Int](repeating: 0, count: k)
        assignment.forEach { n[$0] += 1 }
        return centers.indices.sorted { n[$0] > n[$1] }.map { centers[$0] }
    }

    private static func hex(_ c: SIMD3<Float>) -> String {
        String(format: "#%02X%02X%02X", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
    }
}
