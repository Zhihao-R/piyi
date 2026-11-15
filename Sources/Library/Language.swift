import Foundation

/// 界面是不是中文：打包好的 App 看系统给它选的语言；调试版（swift run、测试）没有翻译表，界面显示代码里的中文，按系统语言算
public var interfaceIsChinese: Bool {
    let language = Bundle.main.localizations.count > 1 ? Bundle.main.preferredLocalizations.first : Locale.preferredLanguages.first
    return language?.hasPrefix("zh") ?? true
}

/// 存在数据里、代码拿来当标识的中文名（格式、平台，如「公众号」「长图」）：显示时按界面语言翻，数据本身不变。
/// 翻译表里没有的原样显示
public func displayed(_ label: String) -> String { Bundle.main.localizedString(forKey: label, value: label, table: nil) }
