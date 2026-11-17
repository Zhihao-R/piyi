import Foundation

/// Quotation marks around board and discussion names in hints: Chinese uses 「」, other languages follow the translation table
func quoted(_ name: String) -> String { String(localized: "「\(name)」") }
