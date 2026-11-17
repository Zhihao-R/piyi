import AVFoundation
import Speech
import Library

/// Transcription: the system's built-in SpeechAnalyzer (macOS 26 and later), running locally.
/// The recognition models are downloaded and updated by the system, adding no files to the app; they run in a system process, using none of the app's memory. About 20x speed: a ten-minute video is transcribed in half a minute.
/// The output language follows the audio itself: Chinese and English models listen at the same time, and the more confident result is kept
public struct SystemSpeech: Transcription {
    public let name = String(localized: "系统语音识别")
    /// If the model isn't installed, the system downloads it on the first transcription
    public let isReady = true
    static let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

    public init() {}

    public func transcribe(_ file: URL) async throws -> [Cue] {
        // Video files (mp4, mov) can also be read directly as audio, taking only the sound. Open first: if it fails (no audio track), analysis hasn't started yet, so no result stream is left waiting for an end that never comes
        let audio = try AVAudioFile(forReading: file)
        let preset = SpeechTranscriber.Preset.transcription
        let transcribers = Self.locales.map {
            SpeechTranscriber(locale: $0, transcriptionOptions: preset.transcriptionOptions, reportingOptions: preset.reportingOptions,
                              attributeOptions: preset.attributeOptions.union([.transcriptionConfidence]))
        }
        if let install = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: transcribers)
        async let heard = withThrowingTaskGroup(of: Heard.self) { group in
            for transcriber in transcribers { group.addTask { try await Self.listen(to: transcriber) } }
            return try await group.reduce(into: [Heard]()) { $0.append($1) }
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            // Finish up even if analysis fails midway, so the result stream ends
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await heard.max { $0.confidence < $1.confidence }?.cues ?? []
    }

    /// What one model heard: sentence-by-sentence subtitles, and the average confidence weighted by character count
    private struct Heard: Sendable {
        var cues: [Cue] = []
        var confidence = 0.0
    }

    private static func listen(to transcriber: SpeechTranscriber) async throws -> Heard {
        var heard = Heard(), weighted = 0.0, characters = 0
        for try await result in transcriber.results {
            heard.cues.append(Cue(start: result.range.start.seconds, end: result.range.end.seconds, text: tidy(String(result.text.characters))))
            for run in result.text.runs {
                guard let confidence = run.attributes[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
                let count = result.text[run.range].characters.count
                weighted += confidence * Double(count); characters += count
            }
        }
        heard.confidence = characters == 0 ? 0 : weighted / Double(characters)
        return heard
    }

    /// The system leaves a space before Chinese punctuation (「过去的一年里 ，我」); remove it
    static func tidy(_ text: String) -> String {
        text.replacing(/\s+([，。！？、；：])/) { $0.output.1 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
