import QuartzCore
import ImageIO
import Library
import Tokens

/// 不带隐式动画的图层
class QuietLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// 一张卡：外层只负责阴影（给定阴影形状，显卡不必逐像素推算轮廓），内层放画好的位图并切圆角。
/// 平时它只是一张图，不是控件；悬停时只把这一张轻轻拿起来。
final class CardLayer: QuietLayer {
    let content = QuietLayer()
    private(set) var item: BoardItem?
    /// 当前位图是按哪个倍率画的
    private(set) var scale: CGFloat = 0
    /// 悬停时拿起来了
    private(set) var lifted = false
    private var shadowOn = false
    private var loading: Task<Void, Never>?
    /// 下一张图到了要和旧图交叉淡化
    private var blends = false
    private var framing: Task<Void, Never>?

    override init() {
        super.init()
        shadowRadius = CardShape.shadow.radius
        shadowOffset = CGSize(width: 0, height: CardShape.shadow.offset)
        content.masksToBounds = true
        content.contentsGravity = .resize
        content.backgroundColor = Palette.placeholder.now.cg
        addSublayer(content)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func bind(_ item: BoardItem) {
        self.item = item
        content.contents = nil
        blends = false
        // 文字类卡片拉大时旧图不拉伸，钉在左上角，新排的图到了再换；空出来的地方是卡片底色
        content.contentsGravity = CardArt.reflows(item.face) ? .topLeft : .resize
        tintBackground()
        place(item.placement)
    }

    /// 同一张卡、同样大小，只是内容变了（理解完了、抽取完了）：旧图留着，新图画好再交叉淡化过去，中间不露底色
    func revise(_ item: BoardItem) {
        self.item = item
        content.contentsGravity = CardArt.reflows(item.face) ? .topLeft : .resize
        tintBackground()
        // 圆角跟着卡的种类走，种类可能变了
        place(item.placement)
        blends = content.contents != nil
    }

    private func tintBackground() {
        guard let item else { return }
        let paper = if case .card(let card) = item.face { Palette.tint(card.tint).now } else { Palette.card.now }
        content.backgroundColor = (CardArt.reflows(item.face) ? paper : Palette.placeholder.now).cg
    }

    /// 外观换了深浅：底色马上换，位图按新颜色重画
    @MainActor func repaint(files: FileStore) {
        tintBackground()
        render(at: scale, files: files)
    }

    /// 按摆放定位置、大小、角度。尺寸变了要重画，由调用方决定
    func place(_ p: Placement) {
        item?.placement = p
        setAffineTransform(.identity)
        bounds = CGRect(origin: .zero, size: p.frame.size)
        position = CGPoint(x: p.frame.midX, y: p.frame.midY)
        setAffineTransform(transform(for: p))
        zPosition = p.z
        content.frame = bounds
        let r = radius
        content.cornerRadius = r
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// 图片本身有边，不切圆角；纸样的卡（文字、网页、文档、音频）和画板入口切圆角
    private var radius: CGFloat {
        if case .card(let card)? = item?.face, card.kind == .image || card.kind == .video { return 0 }
        return CGFloat(CardShape.corner)
    }

    /// 旋转、镜像，拿起来时再放大一点
    func transform(for p: Placement) -> CGAffineTransform {
        let lift = lifted ? CardShape.lift.scale : 1
        return CGAffineTransform(rotationAngle: p.rotation).scaledBy(x: (p.flipX ? -1 : 1) * lift, y: (p.flipY ? -1 : 1) * lift)
    }

    /// 悬停时轻轻拿起来：放大一点、阴影加深，用「拿起」那种短弹簧
    func setLifted(_ on: Bool) {
        guard on != lifted, let p = item?.placement else { return }
        lifted = on
        let from = presentation()?.affineTransform() ?? affineTransform()
        setAffineTransform(transform(for: p))
        let spring = { (key: String, from: Any?) in
            let a = CASpringAnimation(perceptualDuration: Motion.lift.response, bounce: 1 - Motion.lift.damping)
            a.keyPath = key
            a.fromValue = from
            self.add(a, forKey: key)
        }
        spring("transform", CATransform3DMakeAffineTransform(from))
        guard shadowOn else { return }
        let (opacity, radius, offset) = on ? (CardShape.lift.opacity, CardShape.lift.radius, CardShape.lift.offset)
            : (CardShape.shadow.opacity, CardShape.shadow.radius, CardShape.shadow.offset)
        spring("shadowOpacity", presentation()?.shadowOpacity ?? shadowOpacity)
        spring("shadowRadius", presentation()?.shadowRadius ?? shadowRadius)
        spring("shadowOffset", presentation()?.shadowOffset ?? shadowOffset)
        shadowOpacity = Float(opacity)
        shadowRadius = radius
        shadowOffset = CGSize(width: 0, height: offset)
    }

    /// 屏幕上现在的样子：位置、尺寸、变换。飞行中途取动画里的那一帧，接着飞不会跳
    struct Pose {
        var position: CGPoint, size: CGSize, transform: CATransform3D
    }

    var pose: Pose {
        let p = presentation() ?? self
        return Pose(position: p.position, size: p.bounds.size, transform: p.transform)
    }

    func pose(of p: Placement) -> Pose {
        Pose(position: CGPoint(x: p.frame.midX, y: p.frame.midY), size: p.frame.size, transform: CATransform3DMakeAffineTransform(transform(for: p)))
    }

    /// 换位置的动画（FLIP）：图层已经放到终点，从 start 那个样子开始只动画变换，位图和阴影跟着走，不会变形错位
    func fly(from start: Pose) {
        guard let p = item?.placement else { return }
        lifted = false
        shadowOpacity = shadowOn ? Float(CardShape.shadow.opacity) : 0
        shadowRadius = CardShape.shadow.radius
        shadowOffset = CGSize(width: 0, height: CardShape.shadow.offset)
        let end = CATransform3DMakeAffineTransform(transform(for: p))
        transform = end
        let scale = CATransform3DMakeScale(start.size.width / max(bounds.width, 0.001), start.size.height / max(bounds.height, 0.001), 1)
        let move = CATransform3DMakeTranslation(start.position.x - position.x, start.position.y - position.y, 0)
        let a = CASpringAnimation(perceptualDuration: Motion.place.response, bounce: 1 - Motion.place.damping)
        a.keyPath = "transform"
        a.fromValue = CATransform3DConcat(CATransform3DConcat(scale, start.transform), move)
        a.toValue = end
        add(a, forKey: "transform")
    }

    /// 新来的卡：从稍小、透明长到原样
    func appear() {
        let grow = CASpringAnimation(perceptualDuration: Motion.place.response, bounce: 1 - Motion.place.damping)
        grow.keyPath = "transform"
        grow.fromValue = CATransform3DConcat(CATransform3DMakeScale(Motion.emerge, Motion.emerge, 1), transform)
        grow.toValue = transform
        add(grow, forKey: "transform")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = Motion.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        opacity = 1
        add(fade, forKey: "opacity")
    }

    /// 换内容时新换上来的卡：只淡入
    func fadeIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = Motion.swap
        add(fade, forKey: "opacity")
    }

    /// 换内容时同一张卡飞过来、自己的图还没画好：先用旧图层那张顶着，免得飞过来的是一块底色。
    /// 裁剪不同的图不借，拉伸着会错
    func borrow(_ other: CardLayer) {
        guard isPainting, content.contents == nil, other.item?.placement.crop == item?.placement.crop else { return }
        content.contents = other.content.contents
        content.contentsScale = other.content.contentsScale
    }

    /// 离开的卡：淡出，稍微缩小；做完回调
    func vanish(_ done: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presentation()?.opacity ?? opacity
        fade.toValue = 0
        fade.duration = Motion.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        add(fade, forKey: "opacity")
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = presentation()?.transform ?? transform
        shrink.toValue = CATransform3DConcat(CATransform3DMakeScale(0.94, 0.94, 1), transform)
        shrink.duration = Motion.fade
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        add(shrink, forKey: "transform")
        CATransaction.commit()
    }

    /// 淡出途中被叫回来：停下淡出，回到原样
    func stay() {
        removeAnimation(forKey: "opacity")
        removeAnimation(forKey: "transform")
        opacity = 1
    }

    func unbind() {
        loading?.cancel()
        framing?.cancel()
        content.removeAllAnimations()
        isHidden = false
        opacity = 1
        removeAllAnimations()
        lifted = false
        blends = false
        shadowRadius = CardShape.shadow.radius
        shadowOffset = CGSize(width: 0, height: CardShape.shadow.offset)
        item = nil
    }

    /// 缩得很小时阴影看不清，却会让系统合成画面每帧多花十几毫秒，所以关掉
    func setShadow(_ on: Bool) {
        shadowOn = on
        shadowOpacity = on ? Float(lifted ? CardShape.lift.opacity : CardShape.shadow.opacity) : 0
    }

    /// 位图还在画
    var isPainting: Bool { loading != nil }
    /// 图在这么短的时间里到，算是马上就有，不淡入
    private static let instant = 1.0 / 30

    /// 新请求取代旧请求；卡被回收时 unbind 会取消它。新图到之前继续显示旧图
    @MainActor func render(at s: CGFloat, files: FileStore) {
        guard let item else { return }
        loading?.cancel()
        scale = s
        let asked = CACurrentMediaTime()
        loading = Task(priority: .userInitiated) { [weak self] in
            let image = await Painter.bitmap(for: item, scale: s, files: files)
            guard !Task.isCancelled, let self else { return }
            if let image {
                // 第一次拿到图、又等了一阵才到：淡进来，灰底不突然换成图。
                // 一两帧内就画好的不淡（灰底还没被看见）；换清晰度时已有旧图，也不淡。
                // 内容变了的（revise）从旧图慢一点化过去：字和角标在眼前换，快了晃眼
                let arrives = content.contents == nil && CACurrentMediaTime() - asked > Self.instant
                if arrives || blends {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = blends ? Motion.fade : Motion.swap
                    content.add(fade, forKey: "contents")
                }
                blends = false
                // 不拉伸（文字类卡片钉在左上角）时按图的实际清晰度显示，否则高倍率画的图会按像素原样放大
                content.contentsScale = CGFloat(image.width) / max(content.bounds.width, 1)
                content.contents = image
            }
            // 画完就放掉：做完的任务还被引用着，它的运行内存就一直不还（5000 张卡时上百 MB）
            loading = nil
        }
    }

    /// 动图悬停时才动：在后台解出各帧，按原来的节奏循环播放；移开就停
    @MainActor func animate(_ on: Bool, files: FileStore) {
        framing?.cancel()
        guard on else { content.removeAnimation(forKey: "frames"); return }
        guard case .card(let card)? = item?.face, card.form == .animated, let name = card.original ?? card.cover else { return }
        let width = (item?.placement.width ?? 200) * 2
        framing = Task(priority: .userInitiated) { [weak self] in
            guard let frames = await Self.frames(files.url(of: name), maxWidth: width), !Task.isCancelled, let self else { return }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames.images
            animation.keyTimes = frames.times.map { NSNumber(value: $0) }
            animation.duration = frames.duration
            animation.calculationMode = .discrete
            animation.repeatCount = .infinity
            content.add(animation, forKey: "frames")
        }
    }

    @concurrent private nonisolated static func frames(_ url: URL, maxWidth: CGFloat) async -> (images: [CGImage], times: [Double], duration: Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(src), 120)
        guard count > 1 else { return nil }
        var images: [CGImage] = [], delays: [Double] = []
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxWidth]
        for i in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, i, options as CFDictionary) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            images.append(image)
            delays.append(max(delay, 0.02))
        }
        let total = delays.reduce(0, +)
        var t = 0.0
        let times = delays.map { d in defer { t += d }; return t / total }
        return (images, times, total)
    }
}
