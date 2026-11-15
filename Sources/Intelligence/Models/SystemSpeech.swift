import AVFoundation
import Speech
import Library

/// 转录：系统自带的 SpeechAnalyzer（macOS 26 起），在本机跑。
/// 识别模型由系统下载和更新，不往 App 里加文件；模型在系统进程里跑，不占 App 的内存。约 20 倍速，十分钟的视频半分钟转完。
/// 转成什么语言跟音频本身走：中文、英文两个模型同时听，留把握大的那份
public struct SystemSpeech: Transcription {
    public let name = String(localized: "系统语音识别")
    /// 模型没装时，第一次转录由系统下载
    public let isReady = true
    static let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_US")]

    public init() {}

    public func transcribe(_ file: URL) async throws -> [Cue] {
        // 视频文件（mp4、mov）也能直接按音频读，只取声音。先打开：打不开（没有音轨）时还没起分析，不会留下等不到结尾的结果流
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
            // 分析中途出错也要收尾，结果流才会结束
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await heard.max { $0.confidence < $1.confidence }?.cues ?? []
    }

    /// 一个模型听出来的：逐句的字幕，和按字数加权的平均把握
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

    /// 系统在中文标点前留一个空格（「过去的一年里 ，我」），去掉
    static func tidy(_ text: String) -> String {
        text.replacing(/\s+([，。！？、；：])/) { $0.output.1 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
