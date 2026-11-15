import Foundation

/// 界面用的语言（如 zh、en）：打包好的 App 看系统给它选的那种；调试版（swift run、测试）没有翻译表，界面显示的就是代码里的中文
public var interfaceLanguage: String {
    guard Bundle.main.localizations.count > 1, let chosen = Bundle.main.preferredLocalizations.first else { return "zh" }
    return Locale(identifier: chosen).language.languageCode?.identifier ?? "en"
}

/// 存在数据里、代码拿来当标识的中文名（格式、平台，如「公众号」「长图」）：显示时按界面语言翻，数据本身不变。
/// 翻译表里没有的原样显示；新加的名字要补进翻译表（scripts/check_strings.py 会查）
public func displayed(_ label: String) -> String { Bundle.main.localizedString(forKey: label, value: label, table: nil) }
