import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Text recognition in images: text in screenshots, long images, posters, post images, scanned PDFs. Uses the system's built-in image recognition, Simplified Chinese and English, keeping only lines with high confidence
enum TextRecognition {
    static func text(in image: CGImage) async -> String {
        // Recognize long images screen by screen: shrinking the whole thing into one small image makes the text too small to read
        let screen = image.width * 3 / 2
        guard image.height > screen * 2 else { return await recognize(image) }
        var parts: [String] = []
        for top in stride(from: 0, to: image.height, by: screen) {
            guard let slice = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: min(screen, image.height - top))) else { continue }
            parts.append(await recognize(slice))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func text(inImageAt url: URL) async -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        return await text(in: image)
    }

    private static func recognize(_ image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image) else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.5 }
            .map(\.string)
            .joined(separator: "\n")
    }
}
