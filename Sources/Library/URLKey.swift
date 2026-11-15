import Foundation

/// 比较用网址：同一个网页的不同写法得到同一串字符。
/// 去掉追踪参数（按明确的清单），统一大小写、`www.`、结尾斜杠，丢掉 `#` 后面的部分。
/// 原始网址另外保存：小红书的链接去掉参数就打不开，补抓时要用原始的。
public enum URLKey {
    /// 只用来追踪来源、不改变页面内容的参数
    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid", "ref_src", "spm", "spm_id_from",
        "share_source", "share_medium", "share_plat", "share_session_id", "share_tag", "share_from", "share_id",
        "vd_source", "xsec_token", "xsec_source", "si", "isappinstalled", "scene", "clicktime", "enterid",
    ]

    public static func of(_ string: String) -> String? {
        guard var parts = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // http 和 https 指同一个网页
        parts.scheme = "https"
        parts.host = host
        parts.fragment = nil
        if parts.port == 443 || parts.port == 80 { parts.port = nil }
        let kept = (parts.queryItems ?? [])
            .filter { !$0.name.lowercased().hasPrefix("utm_") && !trackingParameters.contains($0.name.lowercased()) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        parts.queryItems = kept.isEmpty ? nil : kept
        while parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path == "/" { parts.path = "" }
        return parts.string
    }

    /// 收的网址跳转到了 final，final 还指着收的那样东西吗（两个都是比较用网址）。失效的链接常被转到首页、上一级栏目，
    /// 那是比它更泛的地方，不能当成它：根路径不算；同一个站里路径比收的那个短也不算。短链接跳到别的站的具体页面算
    static func lands(_ final: String, from requested: String?) -> Bool {
        let segments = { (key: String) in URLComponents(string: key)?.path.split(separator: "/").count ?? 0 }
        guard segments(final) > 0 else { return false }
        guard let requested, URLComponents(string: requested)?.host == URLComponents(string: final)?.host else { return true }
        return segments(final) >= segments(requested)
    }
}
