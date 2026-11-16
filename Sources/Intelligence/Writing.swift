import Foundation
import Library

/// AI 写给人看的文字（标题、描述、要点、灵感、解读、回答、讨论）用界面的语言写。提示词本身保持中文，只在里面说用哪种语言
enum Writing {
    /// 放进提示词里的语言名：中文、英语……
    static var language: String { Locale(identifier: "zh").localizedString(forLanguageCode: interfaceLanguage) ?? "中文" }
    /// 长度限制：中文按字数，别的语言按词数（一个词大约顶两个汉字）
    static func length(_ chars: Int) -> String { interfaceLanguage == "zh" ? "\(chars) 个字" : "\(max(1, chars / 2)) 个词" }
    /// 模型没守住长度时截短，按 length 的同一把尺子：英文按词截，不会截在半个词上
    static func clip(_ text: String, to chars: Int) -> String {
        interfaceLanguage == "zh" ? String(text.prefix(chars)) : text.split(separator: " ").prefix(max(1, chars / 2)).joined(separator: " ")
    }
}
