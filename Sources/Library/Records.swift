import Foundation
import CoreGraphics
import GRDB

/// 卡片按内容长什么样分六类，不按来源：本地 mp4 和 B 站视频都是视频
public enum Kind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case image, text, web, document, video, audio
}

/// 同一类里需要不同处理的形态
public enum Form: String, Codable, Sendable, DatabaseValueConvertible {
    /// 长图：卡片只露开头一截
    case long
    /// 动图：悬停时才动
    case animated
    /// 你的文字：在画板上写的、粘贴或从手机收进来的纯文本。能改、能换底色。
    /// 网页帖子里只有字的（带网址）是别人的原话，不算
    case note
}

/// 抽取进行到哪一步
public enum Extraction: String, Codable, Sendable, DatabaseValueConvertible {
    case extracting
    /// 抽取结束。只拿到一部分时 partial 记着原因
    case complete
}

/// 理解排到哪一步；nil 表示没有要做的
public enum Understanding: String, Codable, Sendable, DatabaseValueConvertible {
    /// 要生成标题和描述：卡片样子马上会变，画布上标「正在理解」
    case generating
    /// 只补算颜色、向量：样子不变，只在状态栏计数
    case indexing
    /// 要生成标题和描述，但还没填密钥（或密钥被拒）。颜色和向量照常算
    case waitingKey
}

/// 资料库里的一条记录：原始内容 + 理解结果
public struct Card: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var kind: Kind
    public var form: Form?
    /// 第一次收进来的时间：再收一次也不改，按天分组、时间筛选都用它
    public var collectedAt: Date
    /// 最近一次又收到它的时间：「全部卡片」按它把这张卡提到最前；没再收过是 nil
    public var resurfacedAt: Date?

    // 原始内容
    /// 收进来的就是这个网址时记在这里（网页卡、直链文件），补抓时用它
    public var url: String?
    /// 比较用网址：按网址查重看它和 finalKey
    public var urlKey: String?
    /// 收的网址跳转到了别处（短链接）时，最终地址的比较用网址：以后收长链接也查得到这张
    public var finalKey: String?
    /// 出处网址：拖进来的图所在的页面，或者收的网址跳转到的最终页面。不参与查重
    public var sourceURL: String?
    /// 内容指纹：按内容查重只看它
    public var fingerprint: String?
    public var title: String?
    /// 出处：作者、网站、文件名
    public var source: String?
    /// 给人看的格式标签：PDF、Markdown、GIF、小红书、B 站…
    public var format: String?
    /// 你亲手写的文字
    public var text: String?
    /// 收的时候和网址一起带来的那句话（「参考 figma.com 定价页的排版」）；重新抓取不动它
    public var note: String?
    /// 你写的文字卡的底色名（见 Palette.tints）；nil 是卡片本来的底色
    public var tint: String?
    /// 抽取出的正文；视频是简介
    public var body: String?
    /// 视频、音频说的话（本机转录，或者平台字幕），格式见 Transcript。没有时总结只是根据简介
    public var transcript: String?
    /// 补全正文（图中文字识别、转录、平台字幕）做完了。分拣要等它
    public var bodyCompleted: Bool
    /// 封面和原文件：文件库里的文件名（内容指纹 + 扩展名）
    public var cover: String?
    public var original: String?
    /// 网上的视频在放大查看里播放用的地址：平台的嵌入播放器，或者视频流（见 Player）。视频不下载，所以没有 original
    public var player: String?
    public var pages: Int?
    /// 秒
    public var duration: Double?
    public var extraction: Extraction
    /// 只拿到一部分的原因；nil 表示完整
    public var partial: Partial?
    /// 进废纸篓的时间；nil 表示没删
    public var trashedAt: Date?

    // 理解结果
    public var generatedTitle: String?
    /// 卡片上显示的一句话
    public var caption: String?
    /// 不显示，只用来算向量的长描述
    public var detail: String?
    public var tags: [String]
    public var summary: String?
    /// 每条要点依据的原文段落，见 SummaryAnchor
    public var summaryAnchors: [SummaryAnchor?]?
    /// 颜色统计，格式由理解决定，资料块只负责存
    public var colors: String?
    /// 生成标题、描述、标签、总结时依据的内容摘要；依据一变就重新排队
    public var understoodBasis: String?
    public var understandError: String?
    public var understanding: Understanding?
    /// 分拣过：不论放没放进别的画板，分过一次就不再自动分
    public var sorted: Bool

    public init(kind: Kind, collectedAt: Date = .now) {
        self.kind = kind
        self.collectedAt = collectedAt
        self.extraction = .extracting
        self.bodyCompleted = false
        self.tags = []
        self.sorted = false
    }

    public static let databaseTableName = "card"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// 显示用的标题：网页、文档、视频保留原标题，图片和文字用模型起的（它们的原标题多半是文件名）。
    /// 画布读的是 CardFace.columns 里同一条规则的 SQL 写法，改这里要一起改
    public var displayTitle: String {
        let preferred = kind == .image || kind == .text ? generatedTitle ?? title : title ?? generatedTitle
        return preferred ?? text.map { String($0.prefix(16)) } ?? ""
    }

    /// 抓到了内容：封面、正文、转录、文字至少有一样
    public var hasContent: Bool { cover != nil || body != nil || transcript != nil || text != nil }

    /// 没抓到内容的残缺卡：标题只是网址或失败页的标题，不能当内容理解
    public var isEmpty: Bool { partial != nil && !hasContent }

    /// 全部正文：正文后面接上转录。理解、搜索读它
    public var fullBody: String? {
        let parts = [body, transcript].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// 理解的依据：只算理解的输入（原标题、正文、你写的文字、封面），不算理解自己写出来的东西，否则会循环重排
    public var contentBasis: String { Self.basis(title: title, body: fullBody, text: text, cover: cover) }

    static func basis(title: String?, body: String?, text: String?, cover: String?) -> String {
        FileStore.fingerprint(Data([title, body, text, cover].map { $0 ?? "" }.joined(separator: "\u{1F}").utf8))
    }
}

/// 多图卡的其余图片，按顺序
public struct CardImage: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public var cardID: Int64
    public var position: Int
    public var file: String

    public static let databaseTableName = "cardImage"
}

/// 每张卡的向量，记着是哪个模型、依据哪段文字算的
public struct Vector: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var cardID: Int64
    public var model: String
    public var basis: String
    public var data: Data

    public init(cardID: Int64, model: String, basis: String, values: [Float]) {
        self.cardID = cardID
        self.model = model
        self.basis = basis
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static let databaseTableName = "vector"
}

public struct Board: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    /// 缩略拼贴：缩略图目录里的文件名
    public var collage: String?
    public var createdAt: Date
    public var openedAt: Date
    /// 自动分拣：关掉后这个画板不再自动收卡
    public var autoSort = true
    /// 分拣规则：一句话说明这个画板收什么；nil 表示没写，按画板里已有的卡判断
    public var rule: String?

    public init(name: String, at date: Date = .now) {
        self.name = name
        self.createdAt = date
        self.openedAt = date
    }

    public static let databaseTableName = "board"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 一张卡或一个画板入口在某个画板里的摆法。cardID 和 entryBoardID 恰好有一个
public struct Placement: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var boardID: Int64
    public var cardID: Int64?
    /// 画板入口指向的画板
    public var entryBoardID: Int64?
    /// 世界坐标，左上角为原点、y 向下
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// 弧度
    public var rotation: Double
    /// 镜像：拖角越过对角时翻过来（先镜像再旋转）
    public var flipX = false
    public var flipY = false
    /// 裁剪框：原图里的一块，按原图宽高归一到 0～1；nil 表示不裁
    public var crop: CGRect?
    /// 叠放顺序，大的在上
    public var z: Double
    /// 新放进标记：分拣放进来的、你还没看过。离开这个画板时清掉
    public var unseen = false

    public init(boardID: Int64, cardID: Int64? = nil, entryBoardID: Int64? = nil, frame: CGRect, z: Double) {
        self.boardID = boardID
        self.cardID = cardID
        self.entryBoardID = entryBoardID
        (x, y, width, height) = (frame.minX, frame.minY, frame.width, frame.height)
        rotation = 0
        self.z = z
    }

    public var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { (x, y, width, height) = (newValue.minX, newValue.minY, newValue.width, newValue.height) }
    }

    public static let databaseTableName = "placement"

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Setting: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var key: String
    public var value: String

    public static let databaseTableName = "setting"
}
