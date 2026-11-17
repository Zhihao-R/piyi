import QuartzCore
import Tokens

/// The old scene kept on screen while switching content (switching boards or the library): the old cards' layers moved in as they were, placed by the old camera
struct Curtain {
    let layer: QuietLayer
    var cards: [CardLayer]
    let camera: Camera
    /// The new scene is already up and this is fading out
    var lifting = false
}

/// Switching content: keep the old scene up while the new one draws the cards in view underneath, then swap it in, so the canvas never goes blank and cards don't pop in one by one.
/// Cards present on both sides fly from their old position to the new one; the rest cross-fade. When switching quickly in a row, only the layer currently visible is kept as the old scene each time
extension CanvasView {
    /// The longest to wait: a wait of a hundred-odd milliseconds hardly feels slow on a click; any longer and it's better to swap in first and fill in the unfinished cards afterwards
    private static let revealDeadline: CFTimeInterval = 0.15

    /// The new scene is still hidden behind the curtain: the overlay (library group titles) doesn't switch yet and keeps the old scene's
    var isBehindCurtain: Bool { curtain?.lifting == false }

    /// Before the new cards go in: move the visible cards into the curtain and hide the world layer for now
    func lowerCurtain() {
        reveal = nil
        if isBehindCurtain {
            // The previous new scene hasn't been swapped in yet and what's visible is still the curtain: just drop the unfinished batch underneath
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
                // The backdrop that covers the other cards while gathering or highlighting also stays in the old scene, or the dimmed cards would all light back up at once
                if veil.opacity > 0 {
                    let v = QuietLayer()
                    v.frame = veil.frame
                    v.backgroundColor = veil.backgroundColor
                    v.opacity = veil.opacity
                    v.zPosition = veil.zPosition
                    c.addSublayer(v)
                }
                // Sits under the world layer: new cards cover the old scene as they fade in and fly over
                layer!.insertSublayer(c, below: world)
                for l in live.values { c.addSublayer(l) }
                curtain = Curtain(layer: c, cards: Array(live.values), camera: camera)
                world.opacity = 0
            }
        }
        live = [:]
    }

    /// All the new cards are placed: wait until the visible ones are drawn, then swap in
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
        // Check once per frame
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120) { [weak self] in self?.waitToReveal(generation, until: deadline) }
    }

    private func liftCurtain() {
        guard var curtain else { return }
        reveal = nil
        world.opacity = 1
        announceReveal()
        // The same card is on both sides: the new layer takes off from how the old layer looked on screen, and the old one is simply dropped. Nothing flies when still
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

        // Group titles switch to the new ones, and the whole overlay cross-fades along with the cards
        let swap = CATransition()
        swap.type = .fade
        swap.duration = Motion.swap
        overlay.add(swap, forKey: "swap")
        updateOverlay()

        // The old scene fades out half a beat later: the new cards cover it first, so the two layers are never both half-transparent and letting the canvas background show through
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

    /// Adds a detail-view dim backdrop on top of the old scene: the outer backdrop is removed at this moment, the old scene fades out still dimmed, and only the new scene brightens
    public func shadeCurtain() {
        guard let curtain else { return }
        let shade = QuietLayer()
        shade.frame = curtain.layer.convert(bounds, from: layer)
        shade.backgroundColor = Palette.backdrop.now.cg
        shade.zPosition = (curtain.cards.map(\.zPosition).max() ?? 0) + 1
        curtain.layer.addSublayer(shade)
    }

    /// The new scene is up: do now the things outside that switch along with it
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
