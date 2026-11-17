import QuartzCore
import AVFoundation
import ImageIO
import Library
import Tokens

/// A layer without implicit animations
class QuietLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// A card: the outer layer only handles the shadow (given a shadow path, so the GPU doesn't have to work out the outline pixel by pixel); the inner layer holds the drawn bitmap and clips the rounded corners.
/// Normally it's just an image, not a control; on hover only this one gets gently lifted.
final class CardLayer: QuietLayer {
    let content = QuietLayer()
    private(set) var item: BoardItem?
    /// The scale the current bitmap was drawn at
    private(set) var scale: CGFloat = 0
    /// Lifted up on hover
    private(set) var lifted = false
    private var shadowOn = false
    private var loading: Task<Void, Never>?
    /// When the next image arrives, cross-fade from the old one
    private var blends = false
    private var framing: Task<Void, Never>?
    /// Local video for hover preview: the one waiting to start and the one playing
    private var previewWait: Task<Void, Never>?
    private var previewing: (player: AVQueuePlayer, looper: AVPlayerLooper, layer: AVPlayerLayer, marks: CALayer)?

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
        // When a text card is stretched, the old image isn't stretched but pinned to the top left until the newly laid-out one arrives; the space left over shows the card color
        content.contentsGravity = CardArt.reflows(item.face) ? .topLeft : .resize
        tintBackground()
        place(item.placement)
    }

    /// Same card, same size, only the content changed (understanding done, extraction done): keep the old image, cross-fade to the new one once drawn, without showing the background in between
    func revise(_ item: BoardItem) {
        self.item = item
        content.contentsGravity = CardArt.reflows(item.face) ? .topLeft : .resize
        tintBackground()
        // Corner radius follows the card kind, which may have changed
        place(item.placement)
        blends = content.contents != nil
    }

    private func tintBackground() {
        guard let item else { return }
        let paper = if case .card(let card) = item.face { Palette.tint(card.tint).now } else { Palette.card.now }
        content.backgroundColor = (CardArt.reflows(item.face) ? paper : Palette.placeholder.now).cg
    }

    /// The appearance switched between light and dark: the background changes immediately and the bitmap is redrawn in the new colors
    @MainActor func repaint(files: FileStore) {
        tintBackground()
        render(at: scale, files: files)
    }

    /// Sets position, size, and angle from the placement. Redrawing when the size changes is the caller's decision
    func place(_ p: Placement) {
        item?.placement = p
        setAffineTransform(.identity)
        bounds = CGRect(origin: .zero, size: p.frame.size)
        position = CGPoint(x: p.frame.midX, y: p.frame.midY)
        setAffineTransform(transform(for: p))
        zPosition = p.z
        content.frame = bounds
        // The previewing video resizes along with the card
        previewing?.layer.frame = content.bounds
        previewing?.marks.frame = content.bounds
        let r = radius
        content.cornerRadius = r
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// Images have their own edges and aren't rounded; paper-style cards (text, web pages, documents, audio) and board entries get rounded corners
    private var radius: CGFloat {
        if case .card(let card)? = item?.face, card.kind == .image || card.kind == .video { return 0 }
        return CGFloat(CardShape.corner)
    }

    /// Rotation, mirroring, and a little extra scale when lifted
    func transform(for p: Placement) -> CGAffineTransform {
        let lift = lifted ? CardShape.lift.scale : 1
        return CGAffineTransform(rotationAngle: p.rotation).scaledBy(x: (p.flipX ? -1 : 1) * lift, y: (p.flipY ? -1 : 1) * lift)
    }

    /// Gently lifted on hover: scaled up a little, shadow deepened, using the short "lift" spring
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

    /// How it looks on screen now: position, size, transform. Mid-flight it takes the current animation frame, so continuing the flight won't jump
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

    /// Move animation (FLIP): the layer is already at its destination; only the transform animates from the start look, and the bitmap and shadow follow without distorting or misaligning
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

    /// A newly arrived card: grows from slightly smaller and transparent to its normal look
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

    /// A card newly swapped in when switching content: fades in only
    func fadeIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = Motion.swap
        add(fade, forKey: "opacity")
    }

    /// When switching content, the same card flies over before its own image is drawn: borrow the old layer's image in the meantime, so what flies over isn't a blank patch of color.
    /// Images with a different crop aren't borrowed; stretched, they'd be wrong
    func borrow(_ other: CardLayer) {
        guard isPainting, content.contents == nil, other.item?.placement.crop == item?.placement.crop else { return }
        content.contents = other.content.contents
        content.contentsScale = other.content.contentsScale
    }

    /// A departing card: fades out and shrinks slightly; calls back when done
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

    /// Called back mid fade-out: stop fading and return to normal
    func stay() {
        removeAnimation(forKey: "opacity")
        removeAnimation(forKey: "transform")
        opacity = 1
    }

    func unbind() {
        loading?.cancel()
        framing?.cancel()
        stopPreview()
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

    /// When zoomed far out the shadow can't be seen, yet costs the system over ten milliseconds of compositing per frame, so turn it off
    func setShadow(_ on: Bool) {
        shadowOn = on
        shadowOpacity = on ? Float(lifted ? CardShape.lift.opacity : CardShape.shadow.opacity) : 0
    }

    /// The bitmap is still being drawn
    var isPainting: Bool { loading != nil }
    /// An image arriving within this short a time counts as immediate and doesn't fade in
    private static let instant = 1.0 / 30

    /// A new request replaces the old one; unbind cancels it when the card is recycled. Keeps showing the old image until the new one arrives
    @MainActor func render(at s: CGFloat, files: FileStore) {
        guard let item else { return }
        loading?.cancel()
        scale = s
        let asked = CACurrentMediaTime()
        loading = Task(priority: .userInitiated) { [weak self] in
            let image = await Painter.bitmap(for: item, scale: s, files: files)
            guard !Task.isCancelled, let self else { return }
            if let image {
                // The first image arrives after a while: fade it in so the gray background doesn't abruptly become the image.
                // No fade if it's drawn within a frame or two (the gray hasn't been seen yet), nor when switching resolution with an old image already there.
                // When the content changed (revise), transition from the old image a bit more slowly: text and badges change right in front of you, and fast is jarring
                let arrives = content.contents == nil && CACurrentMediaTime() - asked > Self.instant
                if arrives || blends {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = blends ? Motion.fade : Motion.swap
                    content.add(fade, forKey: "contents")
                }
                blends = false
                // When not stretched (text cards pinned to the top left), show at the image's actual resolution; otherwise an image drawn at a high scale would be enlarged pixel for pixel
                content.contentsScale = CGFloat(image.width) / max(content.bounds.width, 1)
                content.contents = image
            }
            // Let go once drawn: a finished task that's still referenced never gives back its memory (hundreds of MB with 5000 cards)
            loading = nil
        }
    }

    /// Cards that can move do so on hover and stop when the pointer leaves: animated images play frame by frame, local videos preview muted
    @MainActor func hover(_ on: Bool, files: FileStore) {
        animate(on, files: files)
        preview(on, files: files)
    }

    /// Animated images only move on hover: decode the frames in the background and loop them at their original pace; stop when the pointer leaves
    @MainActor private func animate(_ on: Bool, files: FileStore) {
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

    /// Local videos preview muted on hover, the same habit as animated images only moving on hover: starts after a short dwell (passing over doesn't count),
    /// fades in over the cover once the picture appears, and stops when the pointer leaves. Online videos don't preview: they'd need loading from the network. Cropped cards don't either: the video picture wouldn't match the cropped part
    @MainActor private func preview(_ on: Bool, files: FileStore) {
        stopPreview()
        guard on, let item, case .card(let card) = item.face, card.kind == .video, let name = card.original, item.placement.crop == nil else { return }
        let url = files.url(of: name)
        previewWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Motion.dwell))
            guard !Task.isCancelled, let self else { return }
            let player = AVQueuePlayer(), screen = AVPlayerLayer(player: player)
            player.isMuted = true
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            screen.frame = content.bounds
            screen.videoGravity = .resizeAspectFill
            screen.opacity = 0
            // Badges are drawn on a separate layer over the picture, shown and removed along with it: duration, platform, and status stay visible during preview
            let marks = QuietLayer()
            marks.frame = content.bounds
            screen.addSublayer(marks)
            content.addSublayer(screen)
            previewing = (player, looper, screen, marks)
            player.play()
            marks.contents = await Painter.marks(for: item, scale: scale)
            if Task.isCancelled { return }
            // It's black until the first frame is decoded: wait for it before showing
            while !screen.isReadyForDisplay {
                try? await Task.sleep(for: .milliseconds(30))
                if Task.isCancelled { return }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = Motion.swap
            screen.opacity = 1
            screen.add(fade, forKey: "opacity")
        }
    }

    private func stopPreview() {
        previewWait?.cancel()
        previewWait = nil
        guard let previewing else { return }
        previewing.player.pause()
        previewing.layer.removeFromSuperlayer()
        self.previewing = nil
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
