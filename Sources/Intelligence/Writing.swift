import Foundation
import Library

/// AI 写给人看的文字（标题、描述、要点、灵感、解读、回答、讨论）用哪种语言：跟界面语言走。提示词本身保持中文
enum Writing {
    static var isChinese: Bool { interfaceIsChinese }
    /// 放进提示词里的语言名
    static var language: String { isChinese ? "中文" : "英文" }
    /// 长度限制：中文按字数，英文按单词数（一个英文单词大约顶两个汉字）
    static func length(_ chars: Int) -> String { isChinese ? "\(chars) 个字" : "\(max(1, chars / 2)) 个英文单词" }
}
