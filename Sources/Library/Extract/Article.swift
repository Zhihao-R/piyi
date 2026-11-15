import Foundation

/// 正文里记着配图位置的文章（目前只有公众号）：图的位置单独一行 imageMark，第 k 个对应多图卡的第 k 张其余图片（不算封面）。
/// 标记跟着正文走，截断、补字都不会错位；凡是把正文当纯文字用的地方（模型、搜索、卡片摘录）都先过 plain
public enum Article {
    public static let imageMark = "\u{FFFC}"

    /// 去掉配图标记。卡片摘录在数据库里做同样的事（Boards.swift 的 CardFace.columns），改一处要一起改
    public static func plain(_ body: String) -> String {
        body.replacingOccurrences(of: imageMark + "\n", with: "").replacingOccurrences(of: imageMark, with: "")
    }

    public enum Segment: Equatable { case text(String), image(Int) }

    /// 正文切成文字段和配图，按原顺序。没被标记用上的配图（以前抓的、或正文被模型改写过的）依次放在文末
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

    /// 公众号开头几行的署名：「👤 采访: 壹小姐」→「采访 壹小姐」。后半截要像个名字（短、不带句读），正文句子不会被当成署名
    public static func credit(_ line: String) -> String? {
        guard let match = line.firstMatch(of: #/^[^\p{L}\p{N}]*((?:采访|整理|编辑|排版|作者|撰文|责编|校对|统筹|摄影)[^:：|｜\s]{0,4})\s*[:：|｜]\s*([^，。！？；,.!?;]{1,12})$/#)
        else { return nil }
        return "\(match.1) \(match.2.trimmingCharacters(in: .whitespaces))"
    }
}
