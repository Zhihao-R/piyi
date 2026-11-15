import AVFoundation
import Speech
import Library

/// 转录：系统自带的 SpeechAnalyzer（macOS 26 起），在本机跑。
/// 中文模型由系统下载和更新，不往 App 里加文件；模型在系统进程里跑，不占 App 的内存。约 20 倍速，十分钟的视频半分钟转完
public struct SystemSpeech: Transcription {
    public let name = "系统语音识别"
    /// 中文模型没装时，第一次转录由系统下载
    public let isReady = true
    static let locale = Locale(identifier: "zh_CN")

    public init() {}

    public func transcribe(_ file: URL) async throws -> [Cue] {
        // 视频文件（mp4、mov）也能直接按音频读，只取声音。先打开：打不开（没有音轨）时还没起分析，不会留下等不到结尾的结果流
        let audio = try AVAudioFile(forReading: file)
        let transcriber = SpeechTranscriber(locale: Self.locale, preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let cues = transcriber.results.reduce(into: [Cue]()) {
            $0.append(Cue(start: $1.range.start.seconds, end: $1.range.end.seconds, text: Self.tidy(String($1.text.characters))))
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
        return try await cues
    }

    /// 系统在中文标点前留一个空格（「过去的一年里 ，我」），去掉
    static func tidy(_ text: String) -> String {
        text.replacing(/\s+([，。！？、；：])/) { $0.output.1 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
