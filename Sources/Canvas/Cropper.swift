import AppKit
import Library

/// Cropping: the card switches to the full original image and everything outside the crop frame is dimmed; drag the edges or corners to resize the frame, drag inside to move it. Only changes the placement on this board, never the original image
final class Cropper {
    let id: Int64
    /// Full image, crop frame (world coordinates)
    let full: CGRect
    var crop: CGRect
    let image = QuietLayer()

    init(id: Int64, full: CGRect, crop: CGRect) {
        self.id = id
        self.full = full
        self.crop = crop
        image.frame = full
        image.contentsGravity = .resize
        image.zPosition = .greatestFiniteMagnitude
    }

    /// Crop frame normalized to the full image (origin at top left); nil when barely cropped
    var normalized: CGRect? {
        let r = CGRect(x: (crop.minX - full.minX) / full.width, y: (crop.minY - full.minY) / full.height,
                       width: crop.width / full.width, height: crop.height / full.height)
        return r.insetBy(dx: 0.002, dy: 0.002).contains(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: 0.004, dy: 0.004)) ? nil : r
    }

    /// Where the full image of a placement sits in the world
    static func fullFrame(_ p: Placement) -> CGRect {
        let c = p.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let w = p.width / c.width, h = p.height / c.height
        return CGRect(x: p.x - c.minX * w, y: p.y - c.minY * h, width: w, height: h)
    }
}

extension CanvasView {
    public var isCropping: Bool { cropper != nil }

    /// Can it be cropped: a single selection, on a board, a card with a cover image
    public var canCrop: Bool {
        guard isEditable, selection.count == 1, let item = items[selection.first!], case .card(let card) = item.face else { return false }
        return card.cover != nil
    }

    public func beginCrop() {
        guard canCrop, cropper == nil, let item = items[selection.first!], case .card(let card) = item.face, let cover = card.cover else { return }
        let c = Cropper(id: item.id, full: Cropper.fullFrame(item.placement), crop: item.placement.frame)
        cropper = c
        live[item.id]?.isHidden = true
        world.addSublayer(c.image)
        let url = store.files.thumbnailURL(of: cover, tier: FileStore.tiers.last!)
        Task(priority: .userInitiated) {
            let image = await Self.decodeFull(url)
            c.image.contents = image
        }
        updateOverlay()
        delegate?.canvasStateChanged(self)
    }

    @concurrent nonisolated private static func decodeFull(_ url: URL) async -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// End cropping; when commit is true, write it into the placement: the card becomes the part the crop frame shows
    public func endCrop(commit: Bool) {
        guard let c = cropper else { return }
        cropper = nil
        c.image.removeFromSuperlayer()
        live[c.id]?.isHidden = false
        if commit, var p = items[c.id]?.placement {
            p.crop = c.normalized
            p.frame = c.crop
            self.commit([p], as: String(localized: "裁剪"))
        }
        updateOverlay()
        delegate?.canvasStateChanged(self)
    }

    /// Restore the original: remove the crop and return the card to the full image's size
    public func resetCrop() {
        guard isEditable else { return }
        commit(selectedItems.filter { $0.placement.crop != nil }.map { item in
            var p = item.placement
            p.frame = Cropper.fullFrame(p)
            p.crop = nil
            return p
        }, as: String(localized: "恢复原图"))
    }

    // MARK: Dragging the crop frame

    func cropDown(at p: CGPoint) {
        guard let c = cropper else { return }
        let w = worldPoint(p), slop = 8 / camera.scale
        var edges: Gesture.Edges = []
        if abs(w.x - c.crop.minX) < slop { edges.insert(.left) }
        if abs(w.x - c.crop.maxX) < slop { edges.insert(.right) }
        if abs(w.y - c.crop.minY) < slop { edges.insert(.top) }
        if abs(w.y - c.crop.maxY) < slop { edges.insert(.bottom) }
        if edges.isEmpty, !c.crop.insetBy(dx: -slop, dy: -slop).contains(w) {
            // Clicked outside the frame: finish cropping
            endCrop(commit: true)
            return
        }
        gesture = .crop(edges: edges, start: w, origin: c.crop)
    }

    func cropDragged(to p: CGPoint) {
        guard let c = cropper, case .crop(let edges, let start, let origin) = gesture else { return }
        let w = worldPoint(p), dx = w.x - start.x, dy = w.y - start.y
        let minimum = Grid.unit
        var r = origin
        if edges.isEmpty {
            r.origin.x = min(max(origin.minX + dx, c.full.minX), c.full.maxX - origin.width)
            r.origin.y = min(max(origin.minY + dy, c.full.minY), c.full.maxY - origin.height)
        } else {
            var (x0, y0, x1, y1) = (origin.minX, origin.minY, origin.maxX, origin.maxY)
            if edges.contains(.left) { x0 = min(max(x0 + dx, c.full.minX), x1 - minimum) }
            if edges.contains(.right) { x1 = max(min(x1 + dx, c.full.maxX), x0 + minimum) }
            if edges.contains(.top) { y0 = min(max(y0 + dy, c.full.minY), y1 - minimum) }
            if edges.contains(.bottom) { y1 = max(min(y1 + dy, c.full.maxY), y0 + minimum) }
            r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        c.crop = r
        updateOverlay()
    }
}
