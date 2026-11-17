import Foundation
import Synchronization
import Library

/// How AI writes text for people.
/// Language: what's stored (titles, descriptions, key points) and inspiration use the interface language; discussions, questions and drawn cards follow the language the user speaks. The prompts themselves stay in Chinese and just say which language to use.
/// Style: the style and focus of each item can be changed by the user in Settings (Part); format, sources, language and other parts the program relies on aren't included and stay in each prompt
public enum Writing {
    /// Interface language name put into prompts, in Chinese: 中文, 英语…
    static var language: String { Locale(identifier: "zh").localizedString(forLanguageCode: interfaceLanguage) ?? "中文" }
    /// Length limits: by characters for Chinese, by words for other languages (one word is roughly two Chinese characters)
    static func length(_ chars: Int) -> String { interfaceLanguage == "zh" ? "\(chars) 个字" : "\(max(1, chars / 2)) 个词" }
    /// Truncate when the model ignores the length: by characters if there are Chinese characters, otherwise by words, never mid-word. Based on the text itself, not the interface: discussion names follow the language the user speaks
    static func clip(_ text: String, to chars: Int) -> String {
        text.unicodeScalars.contains(where: \.properties.isIdeographic) ? String(text.prefix(chars))
            : text.split(separator: " ").prefix(max(1, chars / 2)).joined(separator: " ")
    }

    /// The things AI writes, each with a user-editable writing instruction
    public enum Part: String, CaseIterable, Sendable {
        case card, summary, discussion, answer, draw, inspiration

        /// Default instructions, by interface language
        public var standard: String {
            switch self {
            case .card: String(localized: "标题不超过 12 个字。\n描述一句话，40 字以内：写主体和内容，图像类再写风格、色彩和氛围。\n标签 6 到 10 个，覆盖主体、题材、风格、色彩、情绪；只写这件东西本身有的，不猜它能拿来做什么。\n长文和文档概括它在讲什么，而不是描述排版。")
            case .summary: String(localized: "写 3 到 5 条，让人不看原文也能拿到主要信息。\n每条一句，写具体的事实、观点、数字；不写「介绍了」「讨论了」这种转述。")
            case .discussion: String(localized: "像聊天一样自然、简洁，一般两三段以内；内容本来就是并列的几项时才用列表。\n用户讲自己的经历和想法，直接接着聊，不用去卡片里找证据，也不用为卡片里没有而道歉。")
            case .answer: String(localized: "指向具体的卡片和细节，不超过 200 字。")
            case .draw: String(localized: "从这张卡的具体细节出发，回应用户这句话，不写空话。三到五句，不超过 150 字。")
            case .inspiration: String(localized: "一两句，说完就停，不加建议和感想。\n不讲道理；不用比喻，不用破折号。\n不超过 100 字。")
            }
        }

        /// The instruction in use: the edited one if edited, otherwise the default
        public var style: String { Writing.custom.withLock { $0[self] } ?? standard }
    }

    private static let custom = Mutex<[Part: String]>([:])

    /// One instruction was changed in Settings
    public static func setStyle(_ text: String?, for part: Part) {
        custom.withLock { $0[part] = text.flatMap(part.customized) }
    }
}

extension Writing.Part {
    /// Whether what the user wrote counts as edited: empty or identical to the default counts as unedited (nil), and unedited ones follow when the interface language changes
    public func customized(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == standard ? nil : text
    }
}
