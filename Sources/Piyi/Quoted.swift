import Foundation

/// 提示里提到画板、讨论的名字时加的引号：中文用「」，别的语言照翻译表
func quoted(_ name: String) -> String { String(localized: "「\(name)」") }
