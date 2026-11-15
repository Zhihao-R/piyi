// 设计数值：全应用共用的间距、动效、颜色、字号。只有数字，画布和 SwiftUI 界面各自转成自己的写法。
// 新界面先从这里取，不另起数值。

/// 一种颜色，0～1 的 RGB 加透明度
public struct RGBA: Sendable, Equatable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    public func opacity(_ a: Double) -> RGBA { RGBA(r, g, b, self.a * a) }
}

/// 浅色、深色各一份
public struct Themed<Value: Sendable>: Sendable {
    public var light: Value, dark: Value
    public init(light: Value, dark: Value) { (self.light, self.dark) = (light, dark) }
}

public enum Space {
    /// 网格单位（世界坐标），也是卡片之间的标准间距：画布、搜索结果、灵感排布都用它
    public static let unit: Double = 20
    /// 整理成行、几种卡片视图排出来的行高（世界坐标）：常用缩放下一屏能看到四五行
    public static let rowHeight: Double = 220
}

/// 全应用只有四种动起来的方式。新动画先想它属于哪一种，不另起参数
public enum Motion {
    public struct Spring: Sendable { public var response: Double, damping: Double }
    /// 卡片换位置：聚拢、散开、落下、整理
    public static let place = Spring(response: 0.55, damping: 0.82)
    /// 手边的小反馈：悬停、拿起、按钮
    public static let lift = Spring(response: 0.3, damping: 0.75)
    /// 淡入淡出：浮层、面板、提示；卡片在眼前换内容（理解完了）也用它，字在眼前换，快了晃眼
    public static let fade: Double = 0.3
    /// 换内容：切画板、切资料库时新旧画面交叉淡化。比 fade 短，连着快切也不拖
    public static let swap: Double = 0.18
    /// 换内容从头到尾：新画面淡入，旧画面晚半拍淡完。跟着它一起变的（放大查看的压暗）用这段
    public static let swapSpan: Double = swap * 1.5
    /// 一张图从一处飞到另一处：放大查看从卡片飞出、缩回。两头缓中间快，落地干脆，紧接着的面板不用等弹簧的长尾
    public static let fly: Double = 0.4
    /// 长出来时从这么大开始：新来的卡、从卡片那边出来的放大查看
    public static let emerge: Double = 0.92
    /// 等待：一个来回的时长
    public static let wait: Double = 1.6
    /// 一句提示停留多久再淡出；带「撤销」的停两倍，来得及点
    public static let notice: Double = 3
    /// 闪一下：讨论里点了引用，放大查看里那一段的底色停多久再褪
    public static let flash: Double = 1.6
}

public enum Palette {
    /// 画布底色
    public static let canvas = Themed(light: RGBA(0.905, 0.9, 0.885), dark: RGBA(0.085, 0.085, 0.08))
    /// 纸样卡片（文字、网页、文档）的底色和文字色：一套干净的颜色，不按随机规则换纸色。
    /// 深色模式下纸也变深：画面里最亮的应该是图片，不是一块块白纸
    public static let card = Themed(light: RGBA(0.985, 0.982, 0.972), dark: RGBA(0.165, 0.165, 0.16))
    public static let ink = Themed(light: RGBA(0.11, 0.11, 0.10), dark: RGBA(0.93, 0.93, 0.91))
    /// 次要文字（正文节选）和更淡的文字（出处、字数）
    public static let inkSecondary = Themed(light: ink.light.opacity(0.62), dark: ink.dark.opacity(0.62))
    public static let inkTertiary = Themed(light: ink.light.opacity(0.45), dark: ink.dark.opacity(0.45))
    /// 图片还没到时的底色
    public static let placeholder = Themed(light: RGBA(0.86, 0.85, 0.83), dark: RGBA(0.21, 0.21, 0.205))
    /// 选中、对齐线、正在处理
    public static let accent = RGBA(0.0, 0.48, 1.0)
    /// 残缺
    public static let warning = RGBA(0.89, 0.45, 0.13)
    /// 压在图片上的深色和浅色：角标、视频的播放标记
    public static let badge = RGBA(0, 0, 0, 0.5)
    public static let badgeInk = RGBA(1, 1, 1, 0.95)
    /// 封面压标题时，封面底部渐暗到这个颜色，浅色封面上也看得清字
    public static let coverShade = RGBA(0, 0, 0, 0.6)
    /// 窗口顶上垫在后退、标题底下的那层渐隐的起始色：画布底色压七成，往下渐到透明，卡片滑到按钮底下标题照样看得清
    public static let titleShade = Themed(light: canvas.light.opacity(0.7), dark: canvas.dark.opacity(0.7))
    /// 视频画面没到时的底色
    public static let media = RGBA(0.08, 0.08, 0.08)
    /// 盖在内容上压暗的一层：裁剪框外
    public static let scrim = RGBA(0, 0, 0, 0.4)
    /// 放大查看背后压暗的一层：只剩眼前这张卡。深色画布本来就暗，要压得更重才分得出层次
    public static let backdrop = Themed(light: RGBA(0, 0, 0, 0.45), dark: RGBA(0, 0, 0, 0.7))
    /// 放大查看里放画面的那一块、放文字的那一块的底色：都不透明，背后的画布透不过来
    public static let stage = Themed(light: RGBA(0.93, 0.928, 0.92), dark: RGBA(0.075, 0.075, 0.07))
    public static let page = Themed(light: RGBA(0.992, 0.99, 0.985), dark: RGBA(0.135, 0.135, 0.13))
    /// 搜索的颜色筛选按钮上，十二种叫得出名字的颜色各自的色块（按颜色名）
    public static let swatches: [String: RGBA] = [
        "red": RGBA(0.82, 0.20, 0.18), "orange": RGBA(0.93, 0.52, 0.16), "yellow": RGBA(0.95, 0.80, 0.22),
        "green": RGBA(0.30, 0.58, 0.32), "cyan": RGBA(0.20, 0.66, 0.70), "blue": RGBA(0.20, 0.38, 0.78),
        "purple": RGBA(0.52, 0.32, 0.70), "pink": RGBA(0.93, 0.58, 0.70), "brown": RGBA(0.50, 0.34, 0.22),
        "black": RGBA(0.10, 0.10, 0.10), "white": RGBA(0.97, 0.97, 0.95), "gray": RGBA(0.55, 0.55, 0.55),
    ]
    /// 你写的文字卡可以换的底色，按菜单里的顺序；不选就是卡片本来的底色。浅色下是浅底深字；深色下留着色相、压暗一档，配浅字
    public static let tints: [(name: String, color: Themed<RGBA>)] = [
        ("yellow", Themed(light: RGBA(0.99, 0.94, 0.70), dark: RGBA(0.33, 0.29, 0.13))),
        ("pink", Themed(light: RGBA(0.98, 0.87, 0.88), dark: RGBA(0.35, 0.21, 0.23))),
        ("blue", Themed(light: RGBA(0.85, 0.91, 0.98), dark: RGBA(0.17, 0.25, 0.37))),
        ("green", Themed(light: RGBA(0.87, 0.94, 0.84), dark: RGBA(0.19, 0.30, 0.20))),
        ("purple", Themed(light: RGBA(0.91, 0.88, 0.97), dark: RGBA(0.27, 0.23, 0.39))),
    ]
    /// 文字卡的底色：nil 或不认识的名字是卡片本来的底色
    public static func tint(_ name: String?) -> Themed<RGBA> { tints.first { $0.name == name }?.color ?? card }
    /// 资料库分组标题，直接写在画布底色上：组名，和后面淡一些的张数、「选中这一组」
    public static let shelfTitle = Themed(light: RGBA(0.11, 0.11, 0.10, 0.78), dark: RGBA(1, 1, 1, 0.82))
    public static let shelfNote = Themed(light: RGBA(0.11, 0.11, 0.10, 0.42), dark: RGBA(1, 1, 1, 0.42))
    /// 搜索结果聚拢、字面命中亮起时，其余卡片退成背景：盖一层画布底色，这么不透明
    public static let recede = 0.86
    /// 打字时字面命中的卡原地亮起：其余卡只淡下去这么多。这是提示，不是换一种模式，所以比聚拢轻得多
    public static let hint = 0.5
    /// 闪一下的底色：系统的查找高亮色，这么不透明
    public static let flash = 0.45
}

/// 浮在画布上的界面（搜索栏、筛选按钮、文字面板）的尺寸，屏幕点
public enum Chrome {
    /// 浮层离窗口边的距离，也是浮层之间的大间距
    public static let inset: Double = 20
    /// 小间距：搜索栏和筛选按钮之间、按钮之间
    public static let gap: Double = 10
    public static let searchHeight: Double = 44
    public static let searchWidth: Double = 560
    public static let chipHeight: Double = 26
    public static let panelWidth: Double = 300
    /// 聚拢的卡要让开的地方：底部是搜索栏加筛选按钮，右边是文字面板
    public static let searchReserve = inset + searchHeight + gap + chipHeight + inset
    public static let panelReserve = panelWidth + inset * 2
}

/// 阅读页（放大查看里的文字）的字号和间距，屏幕点。宽的是整块阅读页，窄的是画面旁边那一栏
public enum Reading {
    public struct Scale: Sendable, Equatable {
        /// 标题、描述和要点、正文
        public var title, lead, body: Double
        public var lineSpacing, paragraphSpacing: Double
        /// 四周的留白、块与块之间的间距（块内取一半）
        public var padding, gap: Double
    }
    public static let wide = Scale(title: 28, lead: 16, body: 16, lineSpacing: 10, paragraphSpacing: 14, padding: 40, gap: 24)
    public static let narrow = Scale(title: 20, lead: 14, body: 14, lineSpacing: 6, paragraphSpacing: 10, padding: 24, gap: 18)
    /// 整块阅读页多宽、里面的文字一栏多宽；画面旁边那一栏多宽
    public static let pageWidth: Double = 820
    public static let column: Double = 640
    public static let narrowWidth: Double = 340
}

public enum CardShape {
    /// 卡片圆角（世界坐标）。图片本身有边，不切圆角，只给纸样的卡（文字、网页、文档、音频）
    public static let corner: Double = 6
    /// 卡片阴影：透明度、半径、向下偏移（世界坐标）
    public static let shadow = (opacity: 0.15, radius: 3.0, offset: 1.0)
    /// 悬停时拿起来：放大多少、阴影加深到多少
    public static let lift = (scale: 1.025, opacity: 0.28, radius: 10.0, offset: 4.0)
}

/// 卡片上的文字版式。都是相对卡片宽度的比例，卡片放大缩小时版式不变
public enum CardType {
    public static let padding = 0.08
    /// 短文（引文卡）：中文和西文字号、行距
    public static let quoteCJK = 0.088
    public static let quoteLatin = 0.082
    public static let lineSpacing = 0.022
    /// 中文一行约 9 个字，英文约 19 个字母，用来估算引文卡要多高
    public static let quoteCharsPerLine = (cjk: 9.0, latin: 19.0)
    /// 标题、正文、底部一行（出处、字数、域名）
    public static let title = 0.078
    public static let body = 0.046
    public static let footer = 0.036
    /// 标题和正文之间的空隙、正文行距
    public static let gap = 0.03
    public static let bodyLineSpacing = 0.012
    /// 角标文字
    public static let badge = 0.038
    /// 要点和要点之间的空隙
    public static let pointSpacing = 0.016
    /// 多短算短文：短文做引文卡，长文显示标题和开头几段
    public static let shortTextLimit = 140
    /// 你写的文字卡正文字号：比文章正文大，画布上缩远了也读得出
    public static let note = 0.062
}
