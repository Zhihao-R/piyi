import AppKit
import Library
import Tokens

/// How a card looks on screen right now: detail view grows out of it and shrinks back into it when closed
public struct Spot {
    /// Position and size in the window (origin at top left, y down, matching SwiftUI's global coordinates), without rotation
    public let frame: CGRect
    public let rotation: Double
    /// When the canvas shows the whole picture (image or video, not cropped, not flipped, not a long image), that picture's file; detail view can fly the whole picture
    public let cover: String?
    /// For cards that can't fly as a whole picture (text, web pages…), how they look on the canvas right now: detail view expands from it into a panel
    public let face: CGImage?
    /// Which placement it is: when the same card is placed several times, closing returns to the one it was opened from
    public let placement: Int64
}

extension CanvasView {
    /// How this placement looks when in front of you
    public func spot(_ placement: Int64) -> Spot? {
        guard let window, let height = window.contentView?.bounds.height,
              let layer = live[placement], let item = items[placement] else { return nil }
        let p = item.placement
        let c = screenPoint(CGPoint(x: p.frame.midX, y: p.frame.midY))
        let k = camera.scale * (layer.lifted ? CardShape.lift.scale : 1)
        let size = CGSize(width: p.width * k, height: p.height * k)
        let rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        guard rect.intersects(viewport) else { return nil }
        // View coordinates (y down) → window coordinates (y up) → SwiftUI global coordinates (y down)
        let inWindow = convert(CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: size.width, height: size.height), to: nil)
        var cover: String?
        if case .card(let card) = item.face, card.kind == .image || card.kind == .video, card.form != .long,
           p.crop == nil, !p.flipX, !p.flipY {
            cover = card.cover
        }
        let face = cover == nil && item.placement.cardID != nil ? layer.content.contents.map { $0 as! CGImage } : nil
        return Spot(frame: CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height),
                    rotation: p.rotation, cover: cover, face: face, placement: placement)
    }

    /// The placement of this card that's in front of you: the selected one first, otherwise picked by placement ID, so it's the same one every time
    public func spot(ofCard card: Int64) -> Spot? {
        let copies = live.keys.filter { items[$0]?.cardID == card }
        return (copies.first(where: selection.contains) ?? copies.min()).flatMap { spot($0) }
    }

    /// Whether this card is on the canvas in front of you (whether or not it's scrolled into view)
    public func holds(card: Int64) -> Bool {
        items.values.contains { $0.cardID == card }
    }

    /// The card is taken into detail view: this one on the canvas disappears along with its selection frame, as if it had been picked up
    public func hide(_ spot: Spot) {
        live[spot.placement]?.isHidden = true
        live[spot.placement]?.hover(false, files: store.files)
        overlay.isHidden = true
    }

    /// Put it back
    public func reveal(_ spot: Spot) {
        live[spot.placement]?.isHidden = false
        overlay.isHidden = false
    }
}
