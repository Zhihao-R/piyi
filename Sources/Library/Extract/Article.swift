import Foundation

/// An article whose body records where its images go (currently only WeChat Official Accounts): each image position is its own imageMark line, the k-th matching the k-th other image of the multi-image card (not counting the cover).
/// The marks travel with the body, so truncating or adding text doesn't shift them; anywhere the body is used as plain text (model, search, card excerpt) passes through plain first
public enum Article {
    public static let imageMark = "\u{FFFC}"

    /// Remove image marks. The card excerpt does the same in the database (CardFace.columns in Boards.swift); change both together
    public static func plain(_ body: String) -> String {
        body.replacingOccurrences(of: imageMark + "\n", with: "").replacingOccurrences(of: imageMark, with: "")
    }

    public enum Segment: Equatable { case text(String), image(Int) }

    /// Split the body into text segments and images, in original order. Images no mark used (fetched earlier, or the body was rewritten by the model) go at the end in order
    public static func segments(_ body: String, images: Int) -> [Segment] {
        var segments: [Segment] = [], text: [String] = [], k = 0
        let flush = { if !text.isEmpty { segments.append(.text(text.joined(separator: "\n"))); text = [] } }
        for line in body.components(separatedBy: "\n") {
            guard line == imageMark else { text.append(line); continue }
            if k < images { flush(); segments.append(.image(k)) }
            k += 1
        }
        flush()
        return segments + (min(k, images)..<images).map(Segment.image)
    }

    /// Bylines in the first few lines of a WeChat Official Accounts article: 「👤 采访: 壹小姐」→「采访 壹小姐」 ("Interview: Ms. Yi"). The second half must look like a name (short, no punctuation), so body sentences aren't taken as bylines
    public static func credit(_ line: String) -> String? {
        guard let match = line.firstMatch(of: #/^[^\p{L}\p{N}]*((?:采访|整理|编辑|排版|作者|撰文|责编|校对|统筹|摄影)[^:：|｜\s]{0,4})\s*[:：|｜]\s*([^，。！？；,.!?;]{1,12})$/#)
        else { return nil }
        return "\(match.1) \(match.2.trimmingCharacters(in: .whitespaces))"
    }
}
