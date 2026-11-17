import Testing
import Foundation
@testable import Library

/// Online check of platform subtitles: YouTube's API needs no sign-in, so fetch subtitles of a real video directly; it fails first when the platform changes.
/// Bilibili needs the browser's sign-in state, so it can only be tried in the App. `SUBTITLE_CHECK=1 swift test --filter SubtitleCheck`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUBTITLE_CHECK"] == "1")) struct SubtitleCheck {
    @Test func youtube() async throws {
        let cues = try #require(await WebExtractor().subtitles(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        let text = Transcript.text(cues)
        print("YouTube 字幕 \(text.count) 字：\(text.prefix(120))")
        #expect(text.localizedCaseInsensitiveContains("never gonna give you up"))
    }
}
