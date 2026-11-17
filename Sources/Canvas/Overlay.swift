import QuartzCore
import AppKit
import Library
import Tokens

/// One gesture: pan, marquee select, drag, resize, rotate, crop
enum Gesture {
    case none
    /// Previous point (view coordinates)
    case pan(CGPoint)
    /// Start point, current point (view coordinates); what was selected before starting (kept when holding Shift)
    case marquee(CGPoint, CGPoint, base: Set<Int64>)
    case move(Move)
    case resize(Resize)
    case rotate(Rotate)
    /// Which edges of the crop frame are being dragged while cropping (none means moving the whole frame)
    case crop(edges: Edges, start: CGPoint, origin: CGRect)

    struct Move {
        /// The card under the pointer: snapping and guides are computed from it
        var primary: Int64
        var start: CGPoint
        var origins: [Int64: Placement]
        /// The topmost stacking order on the board at pickup
        var top: Double
        /// Open detail view when released without dragging (cards)
        var opensOnClick = false
        var current: [Int64: Placement] = [:]
    }

    struct Resize {
        /// Which cards are being resized (their placement at mouse down)
        var origins: [Int64: Placement]
        /// The area framed by the control at mouse down
        var box: Box
        /// Which corner is being dragged: -1 or 1 in each of x and y
        var corner: CGVector
        /// The opposite corner (world coordinates), which stays fixed while resizing
        var anchor: CGPoint
        /// How far the mouse was from the corner at mouse down (world coordinates): subtracted while resizing so the corner follows the mouse
        var grab: CGVector
        /// Text cards: width and height each follow the mouse (relayout), without keeping the ratio and without mirroring (flipped text can't be read)
        var free = false

        /// The placement when the mouse is at w (world coordinates): the opposite corner stays put, the aspect ratio is kept, and the frame grows until the mouse lands right on its edge (like Keynote and Freeform).
        /// A single card mirrors when dragged past the opposite corner: horizontally it flips left-right, vertically top-bottom; a group scales as a whole by one factor and doesn't mirror
        func placements(at w: CGPoint, minWidth: CGFloat) -> [Int64: Placement] {
            // Switch to the frame's own coordinates (no rotation, no flip): from the opposite corner toward the mouse
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
            // Use whichever direction needs more enlargement: the mouse stays on the card's right or bottom edge, never outside the card
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
        /// Which cards are being rotated (their placement at mouse down)
        var origins: [Int64: Placement]
        /// The area framed by the control at mouse down: the whole group rotates around its center
        var box: Box
        var startAngle: CGFloat
        /// How far it has rotated so far (after snapping)
        var turned: CGFloat = 0

        /// How the frame looks now
        var current: Box { var b = box; b.rotation += turned; return b }

        /// The mouse is at w (world coordinates): rotate by the angle difference from the start point; snap when the frame's angle is within 4° of upright (0°, 90°…); with Shift held, steps of 15°.
        /// A group with differing angles can't be straightened together, so no snapping (Shift steps still apply)
        mutating func turn(to w: CGPoint, steps: Bool) {
            let target = box.rotation + atan2(w.y - box.center.y, w.x - box.center.x) - startAngle
            let step: CGFloat = steps ? .pi / 12 : .pi / 2, near = (target / step).rounded() * step
            let aligned = Box.sharedRotation(of: Array(origins.values)) != nil
            turned = (steps || aligned && abs(target - near) < .pi / 45 ? near : target) - box.rotation
        }

        /// Each card's center rotates around the frame's center, and the card itself rotates by the same angle
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

    /// Cards being dragged, resized, or rotated: not recycled even outside the view
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
    /// Wrap into ±180° (radians)
    var wrappedAngle: CGFloat { atan2(sin(self), cos(self)) }
}

/// The area framed by the control (world coordinates): for one card it's the card itself, rotating with it; for a group it's the frame that just encloses them at the group's angle
struct Box {
    var center: CGPoint
    var size: CGSize
    var rotation: CGFloat = 0

    init(_ p: Placement) {
        center = CGPoint(x: p.frame.midX, y: p.frame.midY)
        size = p.frame.size
        rotation = p.rotation
    }

    /// That angle when these cards all share it (a single card, a group rotated together), otherwise nil.
    /// Angles rotated together differ only by floating-point error, so the threshold is very small
    static func sharedRotation(of placements: [Placement]) -> CGFloat? {
        guard let first = placements.first?.rotation, placements.allSatisfy({ abs(($0.rotation - first).wrappedAngle) < 1e-6 }) else { return nil }
        return first
    }

    /// The frame that just encloses a group of cards, seen at the angle rotation
    init(enclosing placements: [Placement], rotation: CGFloat = 0) {
        let back = CGAffineTransform(rotationAngle: -rotation)
        let r = placements.flatMap { Box($0).corners }.map { $0.applying(back) }
            .reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        center = CGPoint(x: r.midX, y: r.midY).applying(CGAffineTransform(rotationAngle: rotation))
        size = r.size
        self.rotation = rotation
    }

    /// Four corners: top left, top right, bottom right, bottom left (rotated positions if rotated)
    var corners: [CGPoint] {
        let r = CGAffineTransform(rotationAngle: rotation)
        return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { sx, sy in
            let v = CGPoint(x: sx * size.width / 2, y: sy * size.height / 2).applying(r)
            return CGPoint(x: center.x + v.x, y: center.y + v.y)
        }
    }

    /// Enlarged around the center (a hovered, lifted card is slightly larger, so the controls move out of the way)
    func scaled(_ k: CGFloat) -> Box { var b = self; b.size = CGSize(width: size.width * k, height: size.height * k); return b }
}

/// Overlay in screen coordinates (y down): guides, marquee, controls (corner handles, rotate knob, angle readout), and the dimming and crop frame while cropping. There is just one, not growing with the number of cards
final class Overlay: QuietLayer {
    private let guides = CAShapeLayer(), marquee = CAShapeLayer(), handles = CAShapeLayer(), shade = CAShapeLayer()
    /// Radius of the crop frame's corner handles (screen points)
    static let handleRadius: CGFloat = 6
    /// Alignment guides: how far they stand off the card edges, and half the length of the crossbar at each end (screen points)
    static let guideInset: CGFloat = 4, guideBar: CGFloat = 4
    /// Corner handles: tucked into the four inner corners of the frame — how far from the corner, how long the two short strokes; how big a patch at the corner is a resize press (just covering the handle) (screen points)
    static let bracketGap: CGFloat = 8, bracketArm: CGFloat = 14, cornerReach = bracketGap + bracketArm + 2
    /// Rotate knob: normally a small white dot just inside the top-right corner, expanding into a round knob as the mouse nears; sits diagonally below the corner's resize area (screen points)
    static let knobSize: CGFloat = 26, dotSize: CGFloat = 7, knobInset = cornerReach + knobSize / 2
    /// How close the mouse must be to the knob's center to expand it: the knob's radius plus a finger's width
    static let knobReach = knobSize / 2 + 35
    /// Hit areas for pressing and nearing are a bit larger than what's drawn: room for a shaky hand
    static let slop: CGFloat = 4
    /// When the frame's short side is shorter than this (screen points), no rotate knob (expanded, it would cross the frame's midline), and corner handles shrink toward the corners proportionally
    private static let roomy = (knobInset + knobSize / 2) * 2
    private let knob = QuietLayer(), glyph = QuietLayer()
    /// Which group the rotate knob belongs to now and whether it's expanded; nil when not shown
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
        // Guides only fill the gap between two cards, in a muted ink rather than the accent color, so they never read as a card border
        guides.lineWidth = 1
        marquee.strokeColor = Palette.accent.cg
        marquee.fillColor = Palette.accent.opacity(0.08).cg
        marquee.lineWidth = 1
        // Corner handles: short white polylines with a faint shadow, visible on dark and light images alike; no full outline, no accent color
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
        // The small white dot gets the same faint shadow as the corner handles; the knob is drawn scaled down, so scale the shadow radius back up first
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

    /// Source label: a line of text below cards in gathering results that come from other boards. Same style as the corner badges (dark background, white text)
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

    /// Small label with dark background and white text: shared by source labels and the angle readout
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

    /// Top-left corner at at; returns the label's size
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

    /// The angle readout in the middle of the frame while rotating, always upright; nil hides it
    func setReadout(_ string: String?, at center: CGPoint) {
        guard let string else { readout.isHidden = true; return }
        let size = layout(readout, string, at: .zero)
        readout.frame.origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
    }

    /// Library group titles: group name plus card count, written on the canvas background (no backdrop), with text color following light/dark mode. Layers are keyed by group: a group just entering view fades in, ones already there don't flicker
    private var shelfLabels: [Int: CATextLayer] = [:]
    private var spareShelfLabels: [CATextLayer] = []
    nonisolated(unsafe) static let shelfFont = NSFont.systemFont(ofSize: 13, weight: .semibold), shelfNoteFont = NSFont.systemFont(ofSize: 12)

    /// at is the title's bottom-left corner
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

    /// Which group's title screen point p falls on
    func shelf(at p: CGPoint) -> Int? {
        shelfLabels.first { $0.value.frame.insetBy(dx: -4, dy: -4).contains(p) }?.key
    }

    /// Which source label screen point p falls on (returns the placement ID it belongs to)
    func tag(at p: CGPoint) -> Int64? {
        zip(tags, tagIDs).first { !$0.0.isHidden && $0.0.frame.insetBy(dx: -2, dy: -2).contains(p) }?.1
    }

    override func layoutSublayers() {
        for l in [shade, guides, marquee, handles] { l.frame = bounds }
    }

    /// Guides in screen coordinates: each one stands off the card edges by guideInset, with a short crossbar at both ends
    func setGuides(_ lines: [Grid.Guide]) {
        let path = CGMutablePath()
        for g in lines {
            let vertical = abs(g.to.x - g.from.x) < abs(g.to.y - g.from.y)
            let out = CGVector(dx: vertical ? g.side * Self.guideInset : 0, dy: vertical ? 0 : g.side * Self.guideInset)
            let bar = CGVector(dx: vertical ? Self.guideBar : 0, dy: vertical ? 0 : Self.guideBar)
            let a = CGPoint(x: g.from.x + out.dx, y: g.from.y + out.dy), b = CGPoint(x: g.to.x + out.dx, y: g.to.y + out.dy)
            path.move(to: a); path.addLine(to: b)
            for p in [a, b] {
                path.move(to: CGPoint(x: p.x - bar.dx, y: p.y - bar.dy))
                path.addLine(to: CGPoint(x: p.x + bar.dx, y: p.y + bar.dy))
            }
        }
        guides.strokeColor = Palette.inkSecondary.now.cg
        guides.path = path
    }

    func setMarquee(_ rect: CGRect?) { marquee.path = rect.map { CGPath(rect: $0, transform: nil) } }

    /// Draws a viewfinder-style corner handle inside each of a frame's four corners (top left, top right, bottom right, bottom left, screen coordinates); pass empty for none
    func setHandles(_ boxes: [[CGPoint]]) {
        let path = CGMutablePath()
        for corners in boxes where corners.count == 4 {
            let k = Self.fit(corners), gap = Self.bracketGap * k, arm = Self.bracketArm * k
            for (i, c) in corners.enumerated() {
                // Step in a little along each of the two edges
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

    /// Which corner's resize area of the frame screen point p falls in (0…3, same order as corners). A little room is left outside the corner too
    static func corner(at p: CGPoint, of corners: [CGPoint]) -> Int? {
        let reach = cornerReach * fit(corners)
        return corners.indices.first { i in
            let (a, b) = edges(corners, at: i), d = CGPoint(x: p.x - corners[i].x, y: p.y - corners[i].y)
            let s = d.x * a.x + d.y * a.y, t = d.x * b.x + d.y * b.y
            return s >= -slop && t >= -slop && s <= reach && t <= reach
        }
    }

    /// Center of the rotate knob: a short way in diagonally from the top-right corner. nil when the frame is too small to fit it
    static func knobCenter(of corners: [CGPoint]) -> CGPoint? {
        guard fit(corners) == 1 else { return nil }
        let (a, b) = edges(corners, at: 1)
        return CGPoint(x: corners[1].x + (a.x + b.x) * knobInset, y: corners[1].y + (a.y + b.y) * knobInset)
    }

    /// How far corner handles and the rotate knob shrink toward the corners when the frame is small
    private static func fit(_ c: [CGPoint]) -> CGFloat {
        min(1, min(hypot(c[1].x - c[0].x, c[1].y - c[0].y), hypot(c[3].x - c[0].x, c[3].y - c[0].y)) / roomy)
    }

    /// From corner i, the unit directions along its two edges
    private static func edges(_ c: [CGPoint], at i: Int) -> (CGPoint, CGPoint) {
        (unit(c[(i + 1) % 4], from: c[i]), unit(c[(i + 3) % 4], from: c[i]))
    }

    private static func unit(_ p: CGPoint, from c: CGPoint) -> CGPoint {
        let d = max(hypot(p.x - c.x, p.y - c.y), 0.001)
        return CGPoint(x: (p.x - c.x) / d, y: (p.y - c.y) / d)
    }

    /// Rotate knob: at nil hides it. When switching to another group it grows from nothing into a small white dot at the new position; when open it expands into a dark round knob
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
        // Expanding and collapsing is small feedback at hand: size uses the "lift" spring; color follows with a fade
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

    /// Play button on audio cards: things on paper-style cards use the card's own colors — an ink circle and a paper-colored triangle, switching with light/dark mode; the one playing shows pause.
    /// Only for the hovered card and the one playing, two at most, not growing with the number of cards
    private var playKnobs: [QuietLayer] = []
    /// Smallest and largest size of the button on screen (screen points): any smaller can't be hit accurately, so it isn't drawn
    static let playKnob: ClosedRange<CGFloat> = 20...44

    func setPlayButtons(_ list: [(center: CGPoint, size: CGFloat, pause: Bool)]) {
        while playKnobs.count < list.count {
            let knob = QuietLayer(), glyph = QuietLayer()
            knob.opacity = 0
            glyph.contentsGravity = .resizeAspect
            knob.addSublayer(glyph)
            addSublayer(knob)
            playKnobs.append(knob)
        }
        for (i, knob) in playKnobs.enumerated() {
            guard i < list.count else {
                if knob.opacity != 0 { ease(knob, "opacity", to: 0) }
                continue
            }
            let (center, size, pause) = list[i]
            if knob.opacity == 0 { ease(knob, "opacity", to: 1) }
            knob.backgroundColor = Palette.ink.now.cg
            knob.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            knob.position = center
            knob.cornerRadius = size / 2
            let glyph = knob.sublayers![0]
            glyph.frame = knob.bounds.insetBy(dx: size * 0.3, dy: size * 0.3)
            let glyphs = pause ? Self.pauseGlyph : Self.playGlyph
            glyph.contents = Screen.dark ? glyphs.dark : glyphs.light
        }
    }

    /// Overlay fade in/out: transition from how it looks on screen now to value
    private func ease(_ l: CALayer, _ key: String, to value: Any, from: Any? = nil) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from ?? l.presentation()?.value(forKeyPath: key) ?? l.value(forKeyPath: key)
        a.duration = Motion.fade
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.setValue(value, forKeyPath: key)
        l.add(a, forKey: key)
    }

    /// The white arrow in the rotate knob; the paper-colored triangle and pause in the play button, one each for light and dark
    private static let rotateGlyph = glyph("arrow.clockwise", pointSize: 12, color: Palette.badgeInk)
    private static let playGlyph = (light: glyph("play.fill", pointSize: 20, color: Palette.card.light), dark: glyph("play.fill", pointSize: 20, color: Palette.card.dark))
    private static let pauseGlyph = (light: glyph("pause.fill", pointSize: 20, color: Palette.card.light), dark: glyph("pause.fill", pointSize: 20, color: Palette.card.dark))

    /// A system symbol drawn as a single-color image
    private static func glyph(_ name: String, pointSize: CGFloat, color: RGBA) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor(cgColor: color.cg)!.set()
            r.fill(using: .sourceAtop)
            return true
        }
        var rect = CGRect(origin: .zero, size: CGSize(width: symbol.size.width * Screen.scale, height: symbol.size.height * Screen.scale))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Cropping: everything in the full image outside the crop frame is dimmed, with handles drawn at the crop frame's corners
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
