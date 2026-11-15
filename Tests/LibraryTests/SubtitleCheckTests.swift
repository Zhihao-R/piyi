import Testing
import Foundation
@testable import Library

/// 平台字幕的联网检查：YouTube 的接口不用登录，直接取一条真视频的字幕，平台改版时它先失败。
/// B 站要借浏览器的登录状态，只能在 App 里试。`SUBTITLE_CHECK=1 swift test --filter SubtitleCheck`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUBTITLE_CHECK"] == "1")) struct SubtitleCheck {
    @Test func youtube() async throws {
        let cues = try #require(await WebExtractor().subtitles(for: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        let text = Transcript.text(cues)
        print("YouTube 字幕 \(text.count) 字：\(text.prefix(120))")
        #expect(text.localizedCaseInsensitiveContains("never gonna give you up"))
    }
}
