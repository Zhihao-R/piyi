import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Files stored by content fingerprint: the same content is stored once, and the file name is "<fingerprint>.<extension>".
/// Thumbnails come in three width tiers, at thumbs/<tier>/<fingerprint>.jpg.
public struct FileStore: Sendable {
    public static let tiers = [256, 512, 1024]
    /// Cards show at most 1.7 times their width in height; taller images are long images, showing only the top part
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

    /// Where a thumbnail tier lives (the file may not exist yet)
    public func thumbnailURL(of name: String, tier: Int) -> URL {
        thumbnails.appending(path: "\(tier)/\(Self.stem(name)).jpg")
    }

    /// Store some data and return the file name. Skip writing if a file with the same content already exists
    func put(_ data: Data, ext: String) throws -> String {
        let name = Self.fingerprint(data) + Self.suffix(ext)
        let target = url(of: name)
        if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
        return name
    }

    /// Copy a file in and return the file name
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

    /// Delete the file and all its thumbnail tiers
    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(of: name))
        for tier in Self.tiers { try? FileManager.default.removeItem(at: thumbnailURL(of: name, tier: tier)) }
    }

    // MARK: Thumbnails

    /// Make a thumbnail: no wider than this tier, or the original width if narrower. For long images, only the part showing on the card
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

    // MARK: Fingerprint

    public static func fingerprint(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Read large files in chunks instead of all into memory at once
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
