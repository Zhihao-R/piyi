import Foundation

/// The interface language (e.g. zh, en): the packaged app uses whichever the system picked for it; debug builds (swift run, tests) have no translation tables, so the interface shows the Chinese in the code
public var interfaceLanguage: String {
    guard Bundle.main.localizations.count > 1, let chosen = Bundle.main.preferredLocalizations.first else { return "zh" }
    return Locale(identifier: chosen).language.languageCode?.identifier ?? "en"
}

/// Chinese names stored in data and used as identifiers in code (formats, platforms, e.g. 「公众号」 "WeChat", 「长图」 "Long image"): translated to the interface language when displayed; the data itself doesn't change.
/// Ones missing from the translation table are shown as-is; new names must be added to the translation table (scripts/check_strings.py checks)
public func displayed(_ label: String) -> String { Bundle.main.localizedString(forKey: label, value: label, table: nil) }
