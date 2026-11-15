import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Library

/// 手机竖拍的照片常常横着存、另记「转 90°」：卡片的宽高按显示出来的算，不然竖图被放进横卡片、上下被裁掉
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
