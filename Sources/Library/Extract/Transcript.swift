import Foundation

/// One line of subtitles or transcript: from which second to which second, and what was said
public struct Cue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        (self.start, self.end, self.text) = (start, end, text)
    }
}

/// Transcripts are stored as time-based segments, one per line, each starting with its start time ("01:25 what was said").
/// The line-start timestamp is written the same way as chapters in a description (Player.chapters), so clicking it in the detail view plays from there
public enum Transcript {
    /// A segment must be at least this long before breaking at a pause or sentence end; past the longer one it breaks without waiting for a pause (seconds)
    static let shortest = 20.0, longest = 45.0
    /// A gap this long between two lines counts as a pause (seconds)
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

    /// Auto subtitles have no punctuation, so leave a space between lines as a pause; skip it if there's already Chinese punctuation
    private static func joiner(after text: String) -> String {
        text.last.map(Set("，。！？、；：…").contains) == true ? "" : " "
    }

    /// 05:07; past an hour, 1:02:03
    public static func stamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
