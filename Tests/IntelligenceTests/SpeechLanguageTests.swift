import Testing
import Foundation
@testable import Intelligence

/// Transcription follows the audio's own language: make one Chinese and one English clip with the system speech voices, transcribe each, and check the output is in that language.
/// The first run has the system download the Chinese and English recognition models. `SPEECH_CHECK=1 swift test --filter SpeechLanguage`
@Suite struct SpeechLanguage {
    static let enabled = ProcessInfo.processInfo.environment["SPEECH_CHECK"] != nil

    @Test(.enabled(if: enabled), arguments: [
        ("Eddy (中文（中国大陆）)", "收藏的意义不在于存下多少东西，而在于让旧的东西有机会和新的东西相遇。", true),
        ("Samantha", "The power of collage lies not in any single fragment, but in the seams between them.", false),
    ])
    func followsTheAudio(voice: String, line: String, chinese: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = try Process.run(URL(filePath: "/usr/bin/say"), arguments: ["-v", voice, "-o", file.path, line])
        say.waitUntilExit()
        let text = try await SystemSpeech().transcribe(file).map(\.text).joined()
        let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        #expect((han > text.count / 3) == chinese, "转出来的是：\(text)")
    }
}
