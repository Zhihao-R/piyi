import QuartzCore
import Tokens

/// 换内容（切画板、切资料库）时留在屏幕上的旧画面：旧卡片的图层原样挪进来，按旧镜头摆着
struct Curtain {
    let layer: QuietLayer
    var cards: [CardLayer]
    let camera: Camera
    /// 新画面已经换上来，它在淡出
    var lifting = false
}

/// 换内容：旧画面先留着，新画面在底下把眼前的卡画好再换上来，免得画布空一下、卡片一张张冒出来。
/// 两边都有的卡从旧位置飞到新位置，其余的交叉淡化。连着快切时，每次只留眼前看得到的那一层当旧画面
extension CanvasView {
    /// 最多等多久：一百多毫秒以内的等待，点下去几乎觉不出慢；再长就宁可先换上来，没画好的卡后补
    private static let revealDeadline: CFTimeInterval = 0.15

    /// 新画面还藏在幕布后面：这时浮层（资料库分组标题）不跟着换，留着旧画面的
    var isBehindCurtain: Bool { curtain?.lifting == false }

    /// 新卡片放上来之前：把眼前的卡挪进幕布，世界图层先藏起来
    func lowerCurtain() {
        reveal = nil
        if isBehindCurtain {
            // 上一次的新画面还没换上来，眼前看到的仍是幕布：底下没画完的那批直接收掉
            for l in live.values { recycle(l) }
        } else {
            dropCurtain()
            if !live.isEmpty {
                let c = QuietLayer()
                c.anchorPoint = .zero
                c.bounds = .zero
                c.isGeometryFlipped = true
                c.position = world.position
                c.setAffineTransform(world.affineTransform())
                // 聚拢、亮起时盖住其余卡片的那层底色也留在旧画面里，不然暗着的卡会一下全亮回来
                if veil.opacity > 0 {
                    let v = QuietLayer()
                    v.frame = veil.frame
                    v.backgroundColor = veil.backgroundColor
                    v.opacity = veil.opacity
                    v.zPosition = veil.zPosition
                    c.addSublayer(v)
                }
                // 垫在世界图层下面：新卡片淡入、飞过来时盖在旧画面上
                layer!.insertSublayer(c, below: world)
                for l in live.values { c.addSublayer(l) }
                curtain = Curtain(layer: c, cards: Array(live.values), camera: camera)
                world.opacity = 0
            }
        }
        live = [:]
    }

    /// 新卡片都放上了：等眼前的画好再换上来
    func revealWhenPainted() {
        guard curtain != nil else { announceReveal(); return }
        let generation = UUID()
        reveal = generation
        waitToReveal(generation, until: CACurrentMediaTime() + Self.revealDeadline)
    }

    private func waitToReveal(_ generation: UUID, until deadline: CFTimeInterval) {
        guard reveal == generation else { return }
        let seen = index.ids(in: camera.visibleRect(in: bounds.size))
        if CACurrentMediaTime() >= deadline || seen.allSatisfy({ live[$0]?.isPainting != true }) { liftCurtain(); return }
        // 一帧查一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { [weak self] in self?.waitToReveal(generation, until: deadline) }
    }

    private func liftCurtain() {
        guard var curtain else { return }
        reveal = nil
        world.opacity = 1
        announceReveal()
        // 同一张卡两边都有：新图层从旧图层在屏幕上的样子起飞，旧的直接收掉。still 时都不飞
        var waiting: [Int64: Int64] = [:]
        for (id, item) in items where live[id] != nil && !still { if let card = item.cardID { waiting[card] = id } }
        let size = bounds.size, ratio = curtain.camera.scale / camera.scale
        var flew: Set<Int64> = [], stays: [CardLayer] = []
        for old in curtain.cards {
            guard let card = old.item?.cardID, let id = waiting.removeValue(forKey: card), let new = live[id] else { stays.append(old); continue }
            var pose = old.pose
            pose.position = camera.world(at: curtain.camera.view(at: pose.position, in: size), in: size)
            pose.size = CGSize(width: pose.size.width * ratio, height: pose.size.height * ratio)
            new.borrow(old)
            new.fly(from: pose)
            flew.insert(id)
            recycle(old)
        }
        for (id, l) in live where !flew.contains(id) { l.fadeIn() }
        curtain.cards = stays
        curtain.lifting = true
        self.curtain = curtain

        // 分组标题换成新的，整层浮层跟着卡片一起交叉淡化
        let swap = CATransition()
        swap.type = .fade
        swap.duration = Motion.swap
        overlay.add(swap, forKey: "swap")
        updateOverlay()

        // 旧画面晚半拍才淡出：新卡先盖上来，两层不会同时半透明、让画布底色透出来
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.beginTime = CACurrentMediaTime() + Motion.swap / 2
        fade.duration = Motion.swap
        fade.fillMode = .backwards
        curtain.layer.opacity = 0
        curtain.layer.add(fade, forKey: "opacity")
        let lifted = curtain.layer
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.swapSpan) { [weak self] in
            guard let self, self.curtain?.layer === lifted else { return }
            dropCurtain()
        }
    }

    /// 旧画面上补一层放大查看的暗底：外面的暗底在这一刻撤掉，旧画面暗着淡完，变亮的只有新画面
    public func shadeCurtain() {
        guard let curtain else { return }
        let shade = QuietLayer()
        shade.frame = curtain.layer.convert(bounds, from: layer)
        shade.backgroundColor = Palette.backdrop.now.cg
        shade.zPosition = (curtain.cards.map(\.zPosition).max() ?? 0) + 1
        curtain.layer.addSublayer(shade)
    }

    /// 新画面换上来了：外面跟着一起换的事现在做
    private func announceReveal() {
        let done = revealed
        revealed = nil
        done?()
    }

    private func dropCurtain() {
        guard let curtain else { return }
        for l in curtain.cards { recycle(l) }
        curtain.layer.removeFromSuperlayer()
        self.curtain = nil
    }
}
