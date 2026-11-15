import QuartzCore
import AppKit
import Library
import Tokens

/// 一次手势：平移、框选、拖动、缩放、旋转、裁剪
enum Gesture {
    case none
    /// 上一个点（视图坐标）
    case pan(CGPoint)
    /// 起点、当前点（视图坐标）；开始前已经选中的（按住 Shift 时保留）
    case marquee(CGPoint, CGPoint, base: Set<Int64>)
    case move(Move)
    case resize(Resize)
    case rotate(Rotate)
    /// 裁剪中拖动裁剪框的哪几条边（都没有就是整个挪）
    case crop(edges: Edges, start: CGPoint, origin: CGRect)

    struct Move {
        /// 手底下那张：吸附和对齐线按它算
        var primary: Int64
        var start: CGPoint
        var origins: [Int64: Placement]
        /// 拿起时画板里最上面的叠放顺序
        var top: Double
        /// 按下没拖就松手时放大查看（卡片）
        var opensOnClick = false
        var current: [Int64: Placement] = [:]
    }

    struct Resize {
        /// 缩放的是哪几张（按下时的摆法）
        var origins: [Int64: Placement]
        /// 按下时控件框住的范围
        var box: Box
        /// 拖的是哪个角：x、y 方向各是 -1 或 1
        var corner: CGVector
        /// 对角那一点（世界坐标），缩放时它不动
        var anchor: CGPoint
        /// 按下时鼠标离角有多远（世界坐标）：缩放时扣掉，角才贴着鼠标走
        var grab: CGVector
        /// 文字类卡片：宽高各自跟着鼠标走（重新排版），不保持比例，也不镜像（翻过来的字没法读）
        var free = false

        /// 鼠标到了 w（世界坐标）时的摆法：对角不动，保持高宽比，框长到鼠标刚好落在它的边上（和 Keynote、无边记一样）。
        /// 一张时越过对角就镜像：横向越过左右翻，竖向越过上下翻；一组时整组按同一个倍数缩放，不镜像
        func placements(at w: CGPoint, minWidth: CGFloat) -> [Int64: Placement] {
            // 换到框自己的坐标（不转、不翻）：从对角指向鼠标
            let v = CGPoint(x: w.x - grab.dx - anchor.x, y: w.y - grab.dy - anchor.y).applying(CGAffineTransform(rotationAngle: -box.rotation))
            guard origins.count == 1, let (id, o) = origins.first else {
                let smallest = origins.values.map(\.width).min() ?? minWidth
                let scale = max(v.x * corner.dx / box.size.width, v.y * corner.dy / box.size.height, minWidth / smallest)
                return origins.mapValues { o in
                    var p = o
                    p.frame = CGRect(x: anchor.x + (o.x - anchor.x) * scale, y: anchor.y + (o.y - anchor.y) * scale, width: o.width * scale, height: o.height * scale)
                    return p
                }
            }
            return [id: placement(o, v, minWidth: minWidth)]
        }

        private func placement(_ o: Placement, _ v: CGPoint, minWidth: CGFloat) -> Placement {
            if free {
                let size = CGSize(width: max(minWidth, v.x * corner.dx), height: max(minWidth, v.y * corner.dy))
                let half = CGPoint(x: corner.dx * size.width / 2, y: corner.dy * size.height / 2).applying(CGAffineTransform(rotationAngle: o.rotation))
                var p = o
                p.frame = CGRect(x: anchor.x + half.x - size.width / 2, y: anchor.y + half.y - size.height / 2, width: size.width, height: size.height)
                return p
            }
            let sx: CGFloat = v.x * corner.dx < 0 ? -1 : 1, sy: CGFloat = v.y * corner.dy < 0 ? -1 : 1
            // 横竖两个方向谁要的放大多就按谁：鼠标在卡片的右边或下边上，不会跑到卡片外面
            let scale = max(abs(v.x) / o.width, abs(v.y) / o.height)
            let size = CGSize(width: max(minWidth, scale * o.width), height: max(minWidth, scale * o.width) * o.height / o.width)
            let half = CGPoint(x: corner.dx * sx * size.width / 2, y: corner.dy * sy * size.height / 2).applying(CGAffineTransform(rotationAngle: o.rotation))
            var p = o
            p.frame = CGRect(x: anchor.x + half.x - size.width / 2, y: anchor.y + half.y - size.height / 2, width: size.width, height: size.height)
            if sx < 0 { p.flipX.toggle() }
            if sy < 0 { p.flipY.toggle() }
            return p
        }
    }

    struct Rotate {
        /// 转的是哪几张（按下时的摆法）
        var origins: [Int64: Placement]
        /// 按下时控件框住的范围：整组绕它的中心转
        var box: Box
        var startAngle: CGFloat
        /// 已经转了多少（吸附之后）
        var turned: CGFloat = 0

        /// 框现在的样子
        var current: Box { var b = box; b.rotation += turned; return b }

        /// 鼠标到了 w（世界坐标）：按和起点的角度差转，框的角度离摆正（0°、90°…）4° 以内就吸住；按住 Shift 每 15° 一档。
        /// 角度各不相同的一组没法一起回正，不吸（Shift 照样有档）
        mutating func turn(to w: CGPoint, steps: Bool) {
            let target = box.rotation + atan2(w.y - box.center.y, w.x - box.center.x) - startAngle
            let step: CGFloat = steps ? .pi / 12 : .pi / 2, near = (target / step).rounded() * step
            let aligned = Box.sharedRotation(of: Array(origins.values)) != nil
            turned = (steps || aligned && abs(target - near) < .pi / 45 ? near : target) - box.rotation
        }

        /// 每张的中心绕框的中心转，自己也转同样的角度
        var placements: [Int64: Placement] {
            let t = CGAffineTransform(rotationAngle: turned), c = box.center
            return origins.mapValues { o in
                var p = o
                let v = CGPoint(x: o.frame.midX - c.x, y: o.frame.midY - c.y).applying(t)
                p.frame.origin = CGPoint(x: c.x + v.x - o.width / 2, y: c.y + v.y - o.height / 2)
                p.rotation = (o.rotation + turned).wrappedAngle
                return p
            }
        }
    }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    /// 正在被拖动、缩放、旋转的卡：视野外也不回收
    var moving: Set<Int64> {
        switch self {
        case .move(let m): Set(m.origins.keys)
        case .resize(let r): Set(r.origins.keys)
        case .rotate(let r): Set(r.origins.keys)
        default: []
        }
    }
}

extension CGFloat {
    /// 折回 ±180° 以内（弧度）
    var wrappedAngle: CGFloat { atan2(sin(self), cos(self)) }
}

/// 控件框住的范围（世界坐标）：一张卡就是它自己，跟着卡转；一组是按组的角度刚好包住它们的框
struct Box {
    var center: CGPoint
    var size: CGSize
    var rotation: CGFloat = 0

    init(_ p: Placement) {
        center = CGPoint(x: p.frame.midX, y: p.frame.midY)
        size = p.frame.size
        rotation = p.rotation
    }

    /// 这几张的角度都一样（单张、一起转过的一组）时是这个角度，否则为 nil。
    /// 一起转的角度只差浮点误差，所以门槛取得很小
    static func sharedRotation(of placements: [Placement]) -> CGFloat? {
        guard let first = placements.first?.rotation, placements.allSatisfy({ abs(($0.rotation - first).wrappedAngle) < 1e-6 }) else { return nil }
        return first
    }

    /// 一组卡转到 rotation 这个角度看，刚好包住它们的框
    init(enclosing placements: [Placement], rotation: CGFloat = 0) {
        let back = CGAffineTransform(rotationAngle: -rotation)
        let r = placements.flatMap { Box($0).corners }.map { $0.applying(back) }
            .reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        center = CGPoint(x: r.midX, y: r.midY).applying(CGAffineTransform(rotationAngle: rotation))
        size = r.size
        self.rotation = rotation
    }

    /// 四个角：左上、右上、右下、左下（转过的按转后的位置）
    var corners: [CGPoint] {
        let r = CGAffineTransform(rotationAngle: rotation)
        return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { sx, sy in
            let v = CGPoint(x: sx * size.width / 2, y: sy * size.height / 2).applying(r)
            return CGPoint(x: center.x + v.x, y: center.y + v.y)
        }
    }

    /// 绕中心放大（悬停拿起来的卡放大了一点，控件跟着让开）
    func scaled(_ k: CGFloat) -> Box { var b = self; b.size = CGSize(width: size.width * k, height: size.height * k); return b }
}

/// 屏幕坐标（y 向下）的浮层：对齐线、框选框、控件（角标、旋转钮、角度读数）、裁剪时的遮罩和裁剪框。只有一份，不随卡片数量增加
final class Overlay: QuietLayer {
    private let guides = CAShapeLayer(), marquee = CAShapeLayer(), handles = CAShapeLayer(), shade = CAShapeLayer()
    /// 裁剪框四角控制点的半径（屏幕点）
    static let handleRadius: CGFloat = 6
    /// 角标：收在框的四个内角，离角多远、两条短边多长；角上多大一块按下是缩放（刚好罩住角标）（屏幕点）
    static let bracketGap: CGFloat = 8, bracketArm: CGFloat = 14, cornerReach = bracketGap + bracketArm + 2
    /// 旋转钮：平时是右上角里侧一个小白点，鼠标靠近展开成圆钮；紧挨在角上缩放区的斜下方（屏幕点）
    static let knobSize: CGFloat = 26, dotSize: CGFloat = 7, knobInset = cornerReach + knobSize / 2
    /// 鼠标离钮中心多近就展开：钮的半径再多一指宽
    static let knobReach = knobSize / 2 + 35
    /// 按下、靠近的判定比画出来的大一点：鼠标落点有手抖的余地
    static let slop: CGFloat = 4
    /// 框短边不到这么长（屏幕点）时不放旋转钮（展开后会越过框的中线），角标按比例往角上收
    private static let roomy = (knobInset + knobSize / 2) * 2
    private let knob = QuietLayer(), glyph = QuietLayer()
    /// 旋转钮现在属于哪一组、展开着没有；没显示时为 nil
    private var knobOwner: [Int64]?, knobOpen = false
    private lazy var readout: QuietLayer = { let tag = makeTag(); tag.isHidden = true; return tag }()

    override init() {
        super.init()
        isGeometryFlipped = true
        anchorPoint = .zero
        for l in [shade, guides, marquee, handles] {
            l.actions = ["path": NSNull(), "hidden": NSNull(), "shadowPath": NSNull()]
            addSublayer(l)
        }
        shade.fillRule = .evenOdd
        shade.fillColor = Palette.scrim.cg
        guides.strokeColor = Palette.accent.cg
        guides.lineWidth = 1
        marquee.strokeColor = Palette.accent.cg
        marquee.fillColor = Palette.accent.opacity(0.08).cg
        marquee.lineWidth = 1
        // 角标：白色短折线加一圈淡阴影，压在深色、浅色图片上都看得清；不描整圈边，不用强调色
        handles.strokeColor = Palette.badgeInk.cg
        handles.fillColor = nil
        handles.lineWidth = 2
        handles.lineCap = .round
        handles.lineJoin = .round
        handles.shadowColor = Palette.ink.now.cg
        handles.shadowOpacity = 0.45
        handles.shadowRadius = 2
        handles.shadowOffset = .zero
        knob.bounds = CGRect(x: 0, y: 0, width: Self.knobSize, height: Self.knobSize)
        knob.cornerRadius = Self.knobSize / 2
        knob.borderColor = Palette.badgeInk.opacity(0.3).cg
        // 小白点和角标一样的淡阴影；钮是缩小画出来的，阴影半径先放大回去
        knob.shadowColor = handles.shadowColor
        knob.shadowRadius = handles.shadowRadius * Self.knobSize / Self.dotSize
        knob.shadowOffset = .zero
        knob.opacity = 0
        glyph.frame = knob.bounds.insetBy(dx: 6, dy: 6)
        glyph.contents = Self.rotateGlyph
        glyph.contentsGravity = .resizeAspect
        knob.addSublayer(glyph)
        addSublayer(knob)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// 出处标签：聚拢结果里来自别的画板的卡，下面标一行字。和角标同一种样式（深色底、白字）
    private var tags: [QuietLayer] = []
    private var tagIDs: [Int64] = []
    nonisolated(unsafe) static let tagFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    func setTags(_ list: [(id: Int64, text: String, at: CGPoint)]) {
        while tags.count < list.count { tags.append(makeTag()) }
        for (i, tag) in tags.enumerated() {
            guard i < list.count else { tag.isHidden = true; continue }
            let (_, string, at) = list[i]
            layout(tag, string, at: at)
        }
        tagIDs = list.map(\.id)
    }

    /// 深色底、白字的小标签：出处标签和角度读数共用
    private func makeTag() -> QuietLayer {
        let tag = QuietLayer(), text = CATextLayer()
        tag.backgroundColor = Palette.badge.cg
        tag.cornerRadius = 4
        text.actions = ["string": NSNull(), "bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        text.font = Self.tagFont
        text.fontSize = Self.tagFont.pointSize
        text.foregroundColor = Palette.badgeInk.cg
        text.contentsScale = Screen.scale
        tag.addSublayer(text)
        addSublayer(tag)
        return tag
    }

    /// 左上角放在 at；返回标签的大小
    @discardableResult
    private func layout(_ tag: QuietLayer, _ string: String, at: CGPoint) -> CGSize {
        let size = (string as NSString).size(withAttributes: [.font: Self.tagFont])
        tag.isHidden = false
        tag.frame = CGRect(x: at.x, y: at.y, width: ceil(size.width) + 12, height: 18)
        let text = tag.sublayers![0] as! CATextLayer
        text.string = string
        text.frame = CGRect(x: 6, y: (18 - ceil(size.height)) / 2, width: ceil(size.width), height: ceil(size.height))
        return tag.frame.size
    }

    /// 旋转中框正中的角度读数，始终正着；nil 收起
    func setReadout(_ string: String?, at center: CGPoint) {
        guard let string else { readout.isHidden = true; return }
        let size = layout(readout, string, at: .zero)
        readout.frame.origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
    }

    /// 资料库分组标题：组名加张数，写在画布底色上（不加底），跟着深浅色换字色。按组认图层：刚进视野的那组淡入，一直在的不闪
    private var shelfLabels: [Int: CATextLayer] = [:]
    private var spareShelfLabels: [CATextLayer] = []
    nonisolated(unsafe) static let shelfFont = NSFont.systemFont(ofSize: 13, weight: .semibold), shelfNoteFont = NSFont.systemFont(ofSize: 12)

    /// at 是标题左下角
    func setShelves(_ list: [(id: Int, title: String, note: String, at: CGPoint)], dark: Bool) {
        let ids = Set(list.map(\.id))
        for (id, label) in shelfLabels where !ids.contains(id) {
            label.isHidden = true
            spareShelfLabels.append(label)
            shelfLabels[id] = nil
        }
        let ink = { (c: Themed<RGBA>) in NSColor(cgColor: (dark ? c.dark : c.light).cg) ?? .secondaryLabelColor }
        for (id, title, note, at) in list {
            let label = shelfLabels[id] ?? {
                let label = spareShelfLabels.popLast() ?? {
                    let label = CATextLayer()
                    label.actions = ["string": NSNull(), "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull()]
                    label.contentsScale = Screen.scale
                    addSublayer(label)
                    return label
                }()
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = Motion.fade
                label.add(fade, forKey: "opacity")
                label.isHidden = false
                shelfLabels[id] = label
                return label
            }()
            let text = NSMutableAttributedString(string: title, attributes: [.font: Self.shelfFont, .foregroundColor: ink(Palette.shelfTitle)])
            text.append(NSAttributedString(string: "  " + note, attributes: [.font: Self.shelfNoteFont, .foregroundColor: ink(Palette.shelfNote)]))
            let size = text.size()
            label.string = text
            label.frame = CGRect(x: at.x, y: at.y - ceil(size.height), width: ceil(size.width) + 2, height: ceil(size.height))
        }
    }

    /// 屏幕点 p 落在哪一组的标题上
    func shelf(at p: CGPoint) -> Int? {
        shelfLabels.first { $0.value.frame.insetBy(dx: -4, dy: -4).contains(p) }?.key
    }

    /// 屏幕点 p 落在哪个出处标签上（返回它所属的摆放编号）
    func tag(at p: CGPoint) -> Int64? {
        zip(tags, tagIDs).first { !$0.0.isHidden && $0.0.frame.insetBy(dx: -2, dy: -2).contains(p) }?.1
    }

    override func layoutSublayers() {
        for l in [shade, guides, marquee, handles] { l.frame = bounds }
    }

    func setGuides(_ lines: [(CGPoint, CGPoint)]) {
        let path = CGMutablePath()
        for (a, b) in lines { path.move(to: a); path.addLine(to: b) }
        guides.path = path
    }

    func setMarquee(_ rect: CGRect?) { marquee.path = rect.map { CGPath(rect: $0, transform: nil) } }

    /// 每个框四个角（左上、右上、右下、左下，屏幕坐标）里侧画一个取景框式的角标；没有就传空
    func setHandles(_ boxes: [[CGPoint]]) {
        let path = CGMutablePath()
        for corners in boxes where corners.count == 4 {
            let k = Self.fit(corners), gap = Self.bracketGap * k, arm = Self.bracketArm * k
            for (i, c) in corners.enumerated() {
                // 沿两条边往里各走一点
                let (a, b) = Self.edges(corners, at: i)
                let o = CGPoint(x: c.x + (a.x + b.x) * gap, y: c.y + (a.y + b.y) * gap)
                path.move(to: CGPoint(x: o.x + a.x * arm, y: o.y + a.y * arm))
                path.addLine(to: o)
                path.addLine(to: CGPoint(x: o.x + b.x * arm, y: o.y + b.y * arm))
            }
        }
        handles.path = path
        handles.shadowPath = path.copy(strokingWithWidth: handles.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// 屏幕点 p 落在框的哪个角的缩放区（0…3，同 corners 的顺序）。角外侧也留一点余地
    static func corner(at p: CGPoint, of corners: [CGPoint]) -> Int? {
        let reach = cornerReach * fit(corners)
        return corners.indices.first { i in
            let (a, b) = edges(corners, at: i), d = CGPoint(x: p.x - corners[i].x, y: p.y - corners[i].y)
            let s = d.x * a.x + d.y * a.y, t = d.x * b.x + d.y * b.y
            return s >= -slop && t >= -slop && s <= reach && t <= reach
        }
    }

    /// 旋转钮的中心：右上角往里斜着走一段。框太小放不下时为 nil
    static func knobCenter(of corners: [CGPoint]) -> CGPoint? {
        guard fit(corners) == 1 else { return nil }
        let (a, b) = edges(corners, at: 1)
        return CGPoint(x: corners[1].x + (a.x + b.x) * knobInset, y: corners[1].y + (a.y + b.y) * knobInset)
    }

    /// 框小时角标、旋转钮往角上收的比例
    private static func fit(_ c: [CGPoint]) -> CGFloat {
        min(1, min(hypot(c[1].x - c[0].x, c[1].y - c[0].y), hypot(c[3].x - c[0].x, c[3].y - c[0].y)) / roomy)
    }

    /// 从第 i 个角出发，沿两条边的单位方向
    private static func edges(_ c: [CGPoint], at i: Int) -> (CGPoint, CGPoint) {
        (unit(c[(i + 1) % 4], from: c[i]), unit(c[(i + 3) % 4], from: c[i]))
    }

    private static func unit(_ p: CGPoint, from c: CGPoint) -> CGPoint {
        let d = max(hypot(p.x - c.x, p.y - c.y), 0.001)
        return CGPoint(x: (p.x - c.x) / d, y: (p.y - c.y) / d)
    }

    /// 旋转钮：at 为 nil 收起。换了一组时在新位置从无到有长成小白点；open 时展开成深色圆钮
    func setKnob(at center: CGPoint?, open: Bool, owner: [Int64]) {
        guard let center else {
            if knobOwner != nil { ease(knob, "opacity", to: 0) }
            knobOwner = nil
            return
        }
        knob.position = center
        if knobOwner != owner {
            knobOwner = owner
            knobOpen = false
            knob.removeAllAnimations()
            glyph.removeAllAnimations()
            knob.opacity = 1
            knob.backgroundColor = Palette.badgeInk.cg
            knob.borderWidth = 0
            knob.shadowOpacity = handles.shadowOpacity
            glyph.opacity = 0
            ease(knob, "transform", to: Self.dotTransform, from: CATransform3DMakeScale(0.01, 0.01, 1))
        }
        guard open != knobOpen else { return }
        knobOpen = open
        // 展开、收回是手边的小反馈，大小用「拿起」那种弹簧；颜色跟着淡变
        let spring = CASpringAnimation(perceptualDuration: Motion.lift.response, bounce: 1 - Motion.lift.damping)
        spring.keyPath = "transform"
        spring.fromValue = knob.presentation()?.transform ?? knob.transform
        knob.transform = open ? CATransform3DIdentity : Self.dotTransform
        knob.add(spring, forKey: "transform")
        ease(knob, "backgroundColor", to: (open ? Palette.badge : Palette.badgeInk).cg)
        ease(knob, "borderWidth", to: open ? 0.5 : 0)
        ease(knob, "shadowOpacity", to: open ? 0 : handles.shadowOpacity)
        ease(glyph, "opacity", to: open ? 1 : 0)
    }

    private static let dotTransform = CATransform3DMakeScale(dotSize / knobSize, dotSize / knobSize, 1)

    /// 浮层的淡入淡出：从屏幕上现在的样子过渡到 value
    private func ease(_ l: CALayer, _ key: String, to value: Any, from: Any? = nil) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from ?? l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
        a.duration = Motion.fade
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.setValue(value, forKeyPath: key)
        l.add(a, forKey: key)
    }

    /// 旋转钮里的白色箭头
    private static let rotateGlyph: CGImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor(cgColor: Palette.badgeInk.cg)!.set()
            r.fill(using: .sourceAtop)
            return true
        }
        var rect = CGRect(origin: .zero, size: CGSize(width: symbol.size.width * Screen.scale, height: symbol.size.height * Screen.scale))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }()

    /// 裁剪：整张图里裁剪框以外的部分压暗，裁剪框四角画控制点
    func setCrop(full: CGRect?, crop: CGRect?) {
        guard let full, let crop else { shade.path = nil; return }
        let path = CGMutablePath()
        path.addRect(full)
        path.addRect(crop)
        shade.path = path
        let r = Self.handleRadius
        let frame = CGMutablePath()
        frame.addRect(crop)
        for c in [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY), CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.maxX, y: crop.maxY)] {
            frame.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        handles.path = frame
        handles.shadowPath = frame.copy(strokingWithWidth: handles.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }
}
