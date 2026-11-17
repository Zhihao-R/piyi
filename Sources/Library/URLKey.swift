import Foundation

/// URL for comparison: different spellings of the same web page give the same string.
/// Drops tracking parameters (from an explicit list), normalizes case, `www.` and trailing slashes, and drops everything after `#`.
/// The original URL is saved separately: Xiaohongshu links don't open without their parameters, so refetching needs the original.
public enum URLKey {
    /// Parameters that only track the source and don't change the page content
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
        // http and https mean the same page
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

    /// The collected URL redirected to final; does final still point to the collected thing (both are comparison URLs)? Dead links are often redirected to the home page or a parent section,
    /// somewhere broader that can't stand in for it: the root path doesn't count; on the same site, a shorter path than the collected one doesn't count either. A short link redirecting to a specific page on another site counts
    static func lands(_ final: String, from requested: String?) -> Bool {
        let segments = { (key: String) in URLComponents(string: key)?.path.split(separator: "/").count ?? 0 }
        guard segments(final) > 0 else { return false }
        guard let requested, URLComponents(string: requested)?.host == URLComponents(string: final)?.host else { return true }
        return segments(final) >= segments(requested)
    }
}
