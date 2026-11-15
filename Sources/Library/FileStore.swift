import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 按内容指纹存放的文件：同样的内容只存一份，文件名就是「指纹.扩展名」。
/// 缩略图按宽度分三档，放在 thumbs/<档>/<指纹>.jpg。
public struct FileStore: Sendable {
    public static let tiers = [256, 512, 1024]
    /// 卡片最高显示到宽度的 1.7 倍；更长的图是长图，只露开头一截
    public static let maxAspect: CGFloat = 1.7

    let directory: URL
    let thumbnails: URL

    init(root: URL) throws {
        directory = root.appending(path: "files", directoryHint: .isDirectory)
        thumbnails = root.appending(path: "thumbs", directoryHint: .isDirectory)
        for dir in [directory] + Self.tiers.map({ thumbnails.appending(path: "\($0)") }) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func url(of name: String) -> URL { directory.appending(path: name) }

    /// 某一档缩略图的位置（文件不一定已经生成）
    public func thumbnailURL(of name: String, tier: Int) -> URL {
        thumbnails.appending(path: "\(tier)/\(Self.stem(name)).jpg")
    }

    /// 存一份数据，返回文件名。已经有同样内容的文件就不再写
    func put(_ data: Data, ext: String) throws -> String {
        let name = Self.fingerprint(data) + Self.suffix(ext)
        let target = url(of: name)
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        return name
    }

    /// 复制一个文件进来，返回文件名
    func put(contentsOf file: URL) throws -> String {
        let name = try Self.fingerprint(file) + Self.suffix(file.pathExtension)
        let target = url(of: name)
        if !FileManager.default.fileExists(atPath: target.path) {
            let temporary = directory.appending(path: ".\(UUID().uuidString)")
            try FileManager.default.copyItem(at: file, to: temporary)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        }
        return name
    }

    /// 删掉文件和它的各档缩略图
    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(of: name))
        for tier in Self.tiers { try? FileManager.default.removeItem(at: thumbnailURL(of: name, tier: tier)) }
    }

    // MARK: 缩略图

    /// 生成缩略图：宽度不超过这一档，原图更窄就按原宽。长图只取卡片上露出的那一截
    @discardableResult
    func makeThumbnail(of name: String, tier: Int, long: Bool) -> Bool {
        let target = thumbnailURL(of: name, tier: tier)
        if FileManager.default.fileExists(atPath: target.path) { return true }
        guard let source = CGImageSourceCreateWithURL(url(of: name) as CFURL, nil),
              let size = FileExtractor.pixelSize(source) else { return false }
        let scale = min(1, CGFloat(tier) / size.width)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * scale,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        if long, CGFloat(image.height) > CGFloat(image.width) * Self.maxAspect,
           let top = image.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: (CGFloat(image.width) * Self.maxAspect).rounded())) {
            image = top
        }
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: 指纹

    public static func fingerprint(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// 大文件分段读，不一次读进内存
    static func fingerprint(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func suffix(_ ext: String) -> String { ext.isEmpty ? "" : "." + ext.lowercased() }

    static func stem(_ name: String) -> String { name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name }
}
