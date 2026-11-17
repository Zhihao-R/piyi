import Testing
import CoreGraphics
@testable import Canvas
import Library

@Suite struct GridTests {
    @Test func snapsToNearestUnit() {
        #expect(Grid.snap(29) == 20)
        #expect(Grid.snap(31) == 40)
        #expect(Grid.snapped(CGRect(x: 9, y: 51, width: 33, height: 7)) == CGRect(x: 0, y: 60, width: 33, height: 7))
    }

    @Test func alignsFlushEdgeAndDrawsGuide() {
        let neighbor = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Left edge is 4 off the neighbor's left edge: should snap to align and draw a guide
        let moving = CGRect(x: 4, y: 140, width: 80, height: 60)
        let a = Grid.align(moving, to: [neighbor], tolerance: 10, reach: 200)
        #expect(a.dx == -4)
        // The guide only spans the gap between the two cards, on the outer side of their left edges
        #expect(a.guides == [Grid.Guide(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 140), side: -1)])
    }

    @Test func alignsWithOneUnitGapWithoutGuide() {
        let neighbor = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Left edge is 23 from the neighbor's right edge: snaps to one grid step (20) away, no guide
        let moving = CGRect(x: 123, y: 300, width: 80, height: 60)
        let a = Grid.align(moving, to: [neighbor], tolerance: 10, reach: 400)
        #expect(a.dx == -3)
        #expect(a.guides.isEmpty)
    }

    @Test func ignoresFarNeighbors() {
        let far = CGRect(x: 0, y: 0, width: 100, height: 100)
        let moving = CGRect(x: 3, y: 900, width: 80, height: 60)
        #expect(Grid.align(moving, to: [far], tolerance: 10, reach: 200).dx == nil)
    }

    @Test func justifiedRowsFillWidth() {
        let rects = Grid.justify(aspects: [1, 0.5, 1, 1, 2], width: 600, rowHeight: 200, origin: .zero)
        let firstRow = rects.filter { $0.minY == 0 }
        #expect(abs(firstRow.last!.maxX - 600) < 0.001)
        #expect(Set(firstRow.map(\.height)).count == 1)
    }

    @Test func clearanceMovesBatchBelowOthers() {
        let other = CGRect(x: 0, y: 0, width: 200, height: 200)
        let dy = Grid.clearance(for: CGRect(x: 50, y: 50, width: 100, height: 100), avoiding: [other])
        #expect(dy == 170)   // top edge lands at 220: one grid step below the neighbor's bottom edge
    }
}

@Suite struct ResizeTests {
    /// A 200×100 card, dragging the bottom-right corner; the opposite corner (top-left) is at the origin
    func resize(grab: CGVector = .zero) -> Gesture.Resize {
        var p = Placement(boardID: 1, cardID: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), z: 0)
        p.id = 1
        return Gesture.Resize(origins: [1: p], box: Box(p), corner: CGVector(dx: 1, dy: 1), anchor: .zero, grab: grab)
    }

    @Test func cornerFollowsPointerAlongDiagonal() {
        #expect(resize().placements(at: CGPoint(x: 300, y: 150), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 300, height: 150))
        // The mouse was (3, -2) from the corner on press: after subtracting that, the corner stays put
        #expect(resize(grab: CGVector(dx: 3, dy: -2)).placements(at: CGPoint(x: 203, y: 98), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func pointerStaysOnTheCardEdge() {
        // Mouse at (400, 100): horizontally needs 2x, card grows to 400×200, mouse lands on the right edge
        #expect(resize().placements(at: CGPoint(x: 400, y: 100), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 400, height: 200))
        // Mouse at (100, 150): vertically needs 1.5x, mouse lands on the bottom edge
        #expect(resize().placements(at: CGPoint(x: 100, y: 150), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 300, height: 150))
    }

    @Test func crossingTheAnchorMirrors() {
        // Crossing the opposite corner horizontally: flips left-right, card grows to the left of that corner
        let p = resize().placements(at: CGPoint(x: -200, y: 100), minWidth: 40)[1]!
        #expect(p.flipX && !p.flipY)
        #expect(p.frame == CGRect(x: -200, y: 0, width: 200, height: 100))
        // Crossing in both directions: flips both ways
        let q = resize().placements(at: CGPoint(x: -200, y: -100), minWidth: 40)[1]!
        #expect(q.flipX && q.flipY && q.frame == CGRect(x: -200, y: -100, width: 200, height: 100))
    }

    /// Text cards: width and height follow the mouse independently, and don't mirror even past the opposite corner
    @Test func textCardsResizeFreely() {
        var r = resize()
        r.free = true
        #expect(r.placements(at: CGPoint(x: 400, y: 100), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 400, height: 100))
        let crossed = r.placements(at: CGPoint(x: -50, y: 300), minWidth: 40)[1]!
        #expect(crossed.frame == CGRect(x: 0, y: 0, width: 40, height: 300) && !crossed.flipX)
    }
}

@Suite struct GroupTests {
    /// Two 100×100 cards: one at the origin, one at (200, 0); the group's bounding box is 300×100
    let pair: [Int64: Placement] = {
        var a = Placement(boardID: 1, cardID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), z: 0)
        var b = Placement(boardID: 1, cardID: 2, frame: CGRect(x: 200, y: 0, width: 100, height: 100), z: 1)
        a.id = 1
        b.id = 2
        return [1: a, 2: b]
    }()

    /// Dragging the group's bottom-right corner: the opposite corner (top-left) stays put, each card's position and size scale by the same factor, no mirroring
    @Test func groupScalesTogether() {
        let r = Gesture.Resize(origins: pair, box: Box(enclosing: Array(pair.values)), corner: CGVector(dx: 1, dy: 1), anchor: .zero, grab: .zero)
        let placed = r.placements(at: CGPoint(x: 600, y: 200), minWidth: 40)
        #expect(placed[1]!.frame == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(placed[2]!.frame == CGRect(x: 400, y: 0, width: 200, height: 200))
        // Crossing the opposite corner: shrinks until the smallest card is exactly the minimum width, no flip
        let crossed = r.placements(at: CGPoint(x: -100, y: -100), minWidth: 40)
        #expect(crossed[1]!.width == 40 && !crossed[1]!.flipX)
    }

    /// The group rotates around the center of its bounding box: each card's center orbits, and the card itself turns by the same angle
    @Test func groupRotatesAroundItsCenter() {
        let box = Box(enclosing: Array(pair.values))
        var r = Gesture.Rotate(origins: pair, box: box, startAngle: 0)
        // Starting to the right of the center (150, 50), turning to straight below: 90°
        r.turn(to: CGPoint(x: 150, y: 150), steps: false)
        let placed = r.placements
        #expect(abs(placed[1]!.rotation - .pi / 2) < 1e-9)
        #expect(abs(placed[1]!.frame.midX - 150) < 1e-9 && abs(placed[1]!.frame.midY - (-50)) < 1e-9)
        #expect(abs(placed[2]!.frame.midX - 150) < 1e-9 && abs(placed[2]!.frame.midY - 150) < 1e-9)
    }

    /// Snaps upright within 4°; holding Shift steps every 15°
    @Test func rotationSnaps() {
        var r = Gesture.Rotate(origins: pair, box: Box(enclosing: Array(pair.values)), startAngle: 0)
        let at = { (deg: CGFloat) in CGPoint(x: 150 + 100 * cos(deg * .pi / 180), y: 50 + 100 * sin(deg * .pi / 180)) }
        r.turn(to: at(87), steps: false)
        #expect(abs(r.turned - .pi / 2) < 1e-9)
        r.turn(to: at(80), steps: false)
        #expect(abs(r.turned - 80 * .pi / 180) < 1e-9)
        r.turn(to: at(41), steps: true)
        #expect(abs(r.turned - .pi / 4) < 1e-9)
    }

    /// Rotating a group again after it was rotated: snaps upright by each card's own angle, not by how much this turn rotated
    @Test func snapsToUprightAfterEarlierTurns() {
        var turned = pair
        turned[1]!.rotation = .pi / 6
        turned[2]!.rotation = .pi / 6
        var r = Gesture.Rotate(origins: turned, box: Box(enclosing: Array(turned.values), rotation: .pi / 6), startAngle: 0)
        let at = { (deg: CGFloat) in CGPoint(x: r.box.center.x + 100 * cos(deg * .pi / 180), y: r.box.center.y + 100 * sin(deg * .pi / 180)) }
        r.turn(to: at(-27), steps: false)
        #expect(abs(r.turned + .pi / 6) < 1e-9)
        // After snapping upright the box is upright too, and the readout is 0°
        #expect(abs(r.current.rotation) < 1e-9)
    }

    /// A rotated group box: at that angle, it just encloses the whole group
    @Test func rotatedGroupBoxHugsMembers() {
        let r = Gesture.Rotate(origins: pair, box: Box(enclosing: Array(pair.values)), startAngle: 0, turned: .pi / 4)
        let box = Box(enclosing: Array(r.placements.values), rotation: .pi / 4)
        #expect(abs(box.size.width - 300) < 1e-9 && abs(box.size.height - 100) < 1e-9)
        #expect(abs(box.center.x - 150) < 1e-9 && abs(box.center.y - 50) < 1e-9)
    }

    /// A group whose angles all differ can't be straightened together: no snapping; with Shift, steps every 15° by how much it turned
    @Test func mixedAnglesDoNotSnap() {
        var mixed = pair
        mixed[1]!.rotation = .pi / 18
        mixed[2]!.rotation = .pi / 6
        var r = Gesture.Rotate(origins: mixed, box: Box(enclosing: Array(mixed.values)), startAngle: 0)
        let at = { (deg: CGFloat) in CGPoint(x: r.box.center.x + 100 * cos(deg * .pi / 180), y: r.box.center.y + 100 * sin(deg * .pi / 180)) }
        r.turn(to: at(-8), steps: false)
        #expect(abs(r.turned + 8 * .pi / 180) < 1e-9)
        r.turn(to: at(-17), steps: true)
        #expect(abs(r.turned + .pi / 12) < 1e-9)
    }
}
