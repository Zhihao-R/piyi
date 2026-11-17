import Foundation
import Synchronization
import Library

/// AI 写给人看的文字怎么写。
/// 语言：存下来的（标题、描述、要点）和灵感用界面的语言；讨论、提问、抽一张跟着用户说话的语言。提示词本身保持中文，只在里面说用哪种语言。
/// 写法：每样东西的风格和侧重用户可以在设置里改（Part）；格式、出处、语言这些程序要靠的部分不在里面，留在各处提示词里
public enum Writing {
    /// 放进提示词里的界面语言名：中文、英语……
    static var language: String { Locale(identifier: "zh").localizedString(forLanguageCode: interfaceLanguage) ?? "中文" }
    /// 长度限制：中文按字数，别的语言按词数（一个词大约顶两个汉字）
    static func length(_ chars: Int) -> String { interfaceLanguage == "zh" ? "\(chars) 个字" : "\(max(1, chars / 2)) 个词" }
    /// 模型没守住长度时截短：有汉字的按字截，没有的按词截，不会截在半个词上。看文字本身，不看界面：讨论名跟着用户说话的语言
    static func clip(_ text: String, to chars: Int) -> String {
        text.unicodeScalars.contains(where: \.properties.isIdeographic) ? String(text.prefix(chars))
            : text.split(separator: " ").prefix(max(1, chars / 2)).joined(separator: " ")
    }

    /// AI 写的几样东西，每样一段用户可以改的写法要求
    public enum Part: String, CaseIterable, Sendable {
        case card, summary, discussion, answer, draw, inspiration

        /// 默认的要求，按界面语言
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

        /// 现在用的要求：改过的用改过的，没改的用默认
        public var style: String { Writing.custom.withLock { $0[self] } ?? standard }
    }

    private static let custom = Mutex<[Part: String]>([:])

    /// 设置里改了一样的要求
    public static func setStyle(_ text: String?, for part: Part) {
        custom.withLock { $0[part] = text.flatMap(part.customized) }
    }
}

extension Writing.Part {
    /// 用户写的这段算不算改过：空的或和默认相同的算没改（nil），界面语言换了，没改过的跟着换
    public func customized(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == standard ? nil : text
    }
}
