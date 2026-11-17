import Foundation
import Library
import Intelligence
import Canvas

/// Ways to view the library (All Cards, Unsorted, Trash): by default newest to oldest in one stretch, or grouped by day, color, or source
enum LibraryView: String, CaseIterable, Codable, Sendable {
    case recent, day, color, source

    var label: String {
        switch self {
        case .recent: String(localized: "默认")
        case .day: String(localized: "按天")
        case .color: String(localized: "按颜色")
        case .source: String(localized: "按来源")
        }
    }

    var grouping: Grouping? {
        switch self {
        case .recent: nil
        case .day: Self.byDay
        case .color: Self.byColor
        case .source: Self.bySource
        }
    }

    /// One group per day, newest first
    private static let byDay = Grouping { face in
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: face.collectedAt)
        let ago = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: .now)).day ?? 0
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        let title = switch ago {
        case 0: String(localized: "今天")
        case 1: String(localized: "昨天")
        default: day.formatted(sameYear ? .dateTime.month(.defaultDigits).day().weekday(.abbreviated)
                                        : .dateTime.year().month(.defaultDigits).day())
        }
        return Grouping.Group(title: title, rank: -day.timeIntervalSince1970)
    }

    /// One group per main color, groups ordered around the color wheel, black/white/gray after; cards with no visual (text cards, links without a cover) last, text cards first
    private static let byColor = Grouping { face in
        let colors = ColorName.allCases
        guard let color = face.colors.flatMap(ColorProfile.init(json:))?.main else {
            return face.kind == .text ? Grouping.Group(title: String(localized: "文字"), rank: Double(colors.count)) : Grouping.Group(title: String(localized: "其他"), rank: Double(colors.count + 1))
        }
        return Grouping.Group(title: color.label, rank: Double(colors.firstIndex(of: color)!))
    }

    /// One group per source: websites by their familiar names, one group for what you wrote, one for local files and the clipboard; larger groups first
    private static let bySource = Grouping { face in
        guard let host = face.site else {
            return Grouping.Group(title: face.isOwnText ? String(localized: "你写的") : String(localized: "本机"))
        }
        let name = Self.sites.first { domain, _ in host == domain || host.hasSuffix("." + domain) }?.value
        return Grouping.Group(title: name ?? host)
    }

    private static let sites: [String: String] = [
        "xiaohongshu.com": String(localized: "小红书"), "xhslink.com": String(localized: "小红书"), "mp.weixin.qq.com": String(localized: "公众号"), "bilibili.com": String(localized: "哔哩哔哩"), "b23.tv": String(localized: "哔哩哔哩"),
        "youtube.com": "YouTube", "youtu.be": "YouTube", "pinterest.com": "Pinterest", "pin.it": "Pinterest", "x.com": "X", "twitter.com": "X",
        "douyin.com": String(localized: "抖音"), "zhihu.com": String(localized: "知乎"), "weibo.com": String(localized: "微博"), "instagram.com": "Instagram", "dribbble.com": "Dribbble",
        "behance.net": "Behance", "github.com": "GitHub", "douban.com": String(localized: "豆瓣"), "sspai.com": String(localized: "少数派"),
    ]

}
