import Foundation

/// 网上的视频不下载，放大查看里借平台自己的播放器播。
/// 播放地址有两种：平台给别的网站内嵌用的播放器网页，或者视频流本身（X 的视频）
public enum Player {
    /// YouTube 的嵌入播放器。认不出视频编号时返回 nil
    static func youtube(_ url: URL) -> String? {
        WebExtractor.youtubeID(url).map { "https://www.youtube.com/embed/\($0)" }
    }

    /// B 站的嵌入播放器。分 P 的视频按网址里的 ?p= 播那一 P
    static func bilibili(bvid: String, url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value.flatMap(Int.init) ?? 1
        return "https://player.bilibili.com/player.html?bvid=\(bvid)&p=\(p)"
    }

    /// 别的网站在页面里声明的播放器：twitter:player 是给别的网站内嵌用的播放器网页；
    /// og:video 是播放器网页（类型写 text/html）或者视频文件。视频文件只认得出后缀的：播的时候按后缀分，两处要用同一个标准。
    /// 只要 https 的，Flash 那类不要
    static func declared(twitter: String?, video: String?, type: String?) -> String? {
        if let twitter, twitter.hasPrefix("https://") { return twitter }
        guard let video, video.hasPrefix("https://") else { return nil }
        return type?.lowercased() == "text/html" || isStream(video) ? video : nil
    }

    /// 视频流本身（系统播放器直接播），而不是播放器网页
    public static func isStream(_ player: String) -> Bool {
        guard let ext = URL(string: player)?.pathExtension.lowercased() else { return false }
        return ["mp4", "m4v", "mov", "m3u8"].contains(ext)
    }

    /// 能从指定时间开始播：两家的嵌入播放器和视频流。别的网站的播放器不认得参数
    public static func canSeek(_ player: String) -> Bool {
        isStream(player) || isYouTube(player) || isBilibili(player)
    }

    /// 打开时用的地址：点了播放才加载，所以直接自动播放；B 站关弹幕、要高清。start 是秒，视频流由播放器自己跳，不进地址
    public static func url(_ player: String, start: Int) -> URL? {
        guard var parts = URLComponents(string: player) else { return nil }
        var extra: [URLQueryItem] = []
        if isBilibili(player) {
            extra = [.init(name: "autoplay", value: "1"), .init(name: "danmaku", value: "0"), .init(name: "high_quality", value: "1")]
            if start > 0 { extra.append(.init(name: "t", value: "\(start)")) }
        } else if isYouTube(player) {
            extra = [.init(name: "autoplay", value: "1"), .init(name: "rel", value: "0")]
            if start > 0 { extra.append(.init(name: "start", value: "\(start)")) }
        }
        if !extra.isEmpty { parts.queryItems = (parts.queryItems ?? []) + extra }
        return parts.url
    }

    /// 简介里每行开头的时间点（「00:34 作用域胜过提示词」这种章节）：在正文里的位置和秒数。
    /// 只认行首，免得把正文里提到的钟点也当成时间点；超过视频时长的不算
    public static func chapters(in text: String, duration: Double?) -> [(range: NSRange, seconds: Int)] {
        guard let regex = try? NSRegularExpression(pattern: #"^[ \t]*((?:(\d{1,2}):)?(\d{1,2}):(\d{2}))(?=\s|$)"#, options: .anchorsMatchLines) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            func number(_ group: Int) -> Int? {
                match.range(at: group).location == NSNotFound ? nil : Int(ns.substring(with: match.range(at: group)))
            }
            guard let minutes = number(3), let seconds = number(4), seconds < 60 else { return nil }
            let hours = number(2)
            if hours != nil, minutes >= 60 { return nil }
            let total = (hours ?? 0) * 3600 + minutes * 60 + seconds
            if let duration, Double(total) > duration { return nil }
            return (match.range(at: 1), total)
        }
    }

    private static func isYouTube(_ player: String) -> Bool { player.hasPrefix("https://www.youtube.com/embed/") }
    private static func isBilibili(_ player: String) -> Bool { player.hasPrefix("https://player.bilibili.com/") }
}
