import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Library

/// Portrait phone photos are often stored landscape with a separate "rotate 90°" note: card width and height go by how it displays, otherwise portrait images land in landscape cards with the top and bottom cropped
@Suite struct ImageSizeTests {
    private func jpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(png(gray: 0.5, width: width, height: height) as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test func turnedPhotoSwapsWidthAndHeight() throws {
        #expect(FileExtractor.pixelSize(try jpeg(width: 40, height: 30, orientation: 6)) == CGSize(width: 30, height: 40))
    }

    @Test func uprightPhotoKeepsWidthAndHeight() throws {
        #expect(FileExtractor.pixelSize(try jpeg(width: 40, height: 30, orientation: 1)) == CGSize(width: 40, height: 30))
    }
}
