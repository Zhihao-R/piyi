import Foundation

/// 字幕、转录里的一句：从第几秒说到第几秒、说了什么
public struct Cue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        (self.start, self.end, self.text) = (start, end, text)
    }
}

/// 转录存成按时间分的段，一段一行，行首是这段开始的时间点（「01:25 说的话」）。
/// 行首时间点和简介里的章节是同一个写法（Player.chapters），放大查看里点了就从那里播
public enum Transcript {
    /// 一段至少这么长才在停顿、句末另起；再长就不等停顿直接另起（秒）
    static let shortest = 20.0, longest = 45.0
    /// 两句之间空这么久算停顿（秒）
    static let pause = 1.0

    public static func text(_ cues: [Cue]) -> String {
        var paragraphs: [(start: Double, text: String)] = []
        var last: Cue?
        for cue in cues {
            let said = cue.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !said.isEmpty else { continue }
            if let last, let current = paragraphs.last, !breaks(after: last, before: cue, since: current.start) {
                paragraphs[paragraphs.count - 1].text += joiner(after: current.text) + said
            } else {
                paragraphs.append((cue.start, said))
            }
            last = Cue(start: cue.start, end: cue.end, text: said)
        }
        return paragraphs.map { stamp($0.start) + " " + $0.text }.joined(separator: "\n")
    }

    private static func breaks(after last: Cue, before next: Cue, since start: Double) -> Bool {
        let length = next.start - start
        guard length >= shortest else { return false }
        return length >= longest || next.start - last.end >= pause || last.text.last.map(sentenceEnds.contains) == true
    }

    private static let sentenceEnds = Set("。！？.!?")

    /// 自动字幕没有标点，句与句之间留个空格当停顿；已经有中文标点就不再留
    private static func joiner(after text: String) -> String {
        text.last.map(Set("，。！？、；：…").contains) == true ? "" : " "
    }

    /// 05:07；过了一小时 1:02:03
    public static func stamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
