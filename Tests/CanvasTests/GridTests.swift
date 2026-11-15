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
        // 左边比邻居左边偏 4，应吸过去对齐并画线
        let moving = CGRect(x: 4, y: 140, width: 80, height: 60)
        let a = Grid.align(moving, to: [neighbor], tolerance: 10, reach: 200)
        #expect(a.dx == -4)
        #expect(a.guides.contains { $0.from.x == 0 && $0.to.x == 0 })
    }

    @Test func alignsWithOneUnitGapWithoutGuide() {
        let neighbor = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 左边离邻居右边 23，吸到隔一格（20）贴着，不画线
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
        #expect(dy == 170)   // 顶边落到 220：邻居底边再隔一格
    }
}

@Suite struct ResizeTests {
    /// 200×100 的卡，拖右下角；对角（左上）在原点
    func resize(grab: CGVector = .zero) -> Gesture.Resize {
        var p = Placement(boardID: 1, cardID: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), z: 0)
        p.id = 1
        return Gesture.Resize(origins: [1: p], box: Box(p), corner: CGVector(dx: 1, dy: 1), anchor: .zero, grab: grab)
    }

    @Test func cornerFollowsPointerAlongDiagonal() {
        #expect(resize().placements(at: CGPoint(x: 300, y: 150), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 300, height: 150))
        // 按下时鼠标离角 (3, -2)：扣掉以后角还在原处
        #expect(resize(grab: CGVector(dx: 3, dy: -2)).placements(at: CGPoint(x: 203, y: 98), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func pointerStaysOnTheCardEdge() {
        // 鼠标在 (400, 100)：横向要放大 2 倍，卡长到 400×200，鼠标落在右边上
        #expect(resize().placements(at: CGPoint(x: 400, y: 100), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 400, height: 200))
        // 鼠标在 (100, 150)：竖向要放大 1.5 倍，鼠标落在下边上
        #expect(resize().placements(at: CGPoint(x: 100, y: 150), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 300, height: 150))
    }

    @Test func crossingTheAnchorMirrors() {
        // 横向越过对角：左右翻，卡长到对角左边
        let p = resize().placements(at: CGPoint(x: -200, y: 100), minWidth: 40)[1]!
        #expect(p.flipX && !p.flipY)
        #expect(p.frame == CGRect(x: -200, y: 0, width: 200, height: 100))
        // 两个方向都越过：上下左右都翻
        let q = resize().placements(at: CGPoint(x: -200, y: -100), minWidth: 40)[1]!
        #expect(q.flipX && q.flipY && q.frame == CGRect(x: -200, y: -100, width: 200, height: 100))
    }

    /// 文字类卡片：宽高各自跟着鼠标走，越过对角也不镜像
    @Test func textCardsResizeFreely() {
        var r = resize()
        r.free = true
        #expect(r.placements(at: CGPoint(x: 400, y: 100), minWidth: 40)[1]!.frame == CGRect(x: 0, y: 0, width: 400, height: 100))
        let crossed = r.placements(at: CGPoint(x: -50, y: 300), minWidth: 40)[1]!
        #expect(crossed.frame == CGRect(x: 0, y: 0, width: 40, height: 300) && !crossed.flipX)
    }
}

@Suite struct GroupTests {
    /// 两张 100×100：一张在原点，一张在 (200, 0)；整组外框 300×100
    let pair: [Int64: Placement] = {
        var a = Placement(boardID: 1, cardID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), z: 0)
        var b = Placement(boardID: 1, cardID: 2, frame: CGRect(x: 200, y: 0, width: 100, height: 100), z: 1)
        a.id = 1
        b.id = 2
        return [1: a, 2: b]
    }()

    /// 拖整组的右下角：对角（左上）不动，每张的位置和大小按同一个倍数放大，不镜像
    @Test func groupScalesTogether() {
        let r = Gesture.Resize(origins: pair, box: Box(enclosing: Array(pair.values)), corner: CGVector(dx: 1, dy: 1), anchor: .zero, grab: .zero)
        let placed = r.placements(at: CGPoint(x: 600, y: 200), minWidth: 40)
        #expect(placed[1]!.frame == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(placed[2]!.frame == CGRect(x: 400, y: 0, width: 200, height: 200))
        // 越过对角：缩到最小那张刚好是最小宽度，不翻
        let crossed = r.placements(at: CGPoint(x: -100, y: -100), minWidth: 40)
        #expect(crossed[1]!.width == 40 && !crossed[1]!.flipX)
    }

    /// 整组绕外框中心转：每张的中心跟着绕，自己也转同样的角度
    @Test func groupRotatesAroundItsCenter() {
        let box = Box(enclosing: Array(pair.values))
        var r = Gesture.Rotate(origins: pair, box: box, startAngle: 0)
        // 从中心 (150, 50) 右边开始，转到正下方：90°
        r.turn(to: CGPoint(x: 150, y: 150), steps: false)
        let placed = r.placements
        #expect(abs(placed[1]!.rotation - .pi / 2) < 1e-9)
        #expect(abs(placed[1]!.frame.midX - 150) < 1e-9 && abs(placed[1]!.frame.midY - (-50)) < 1e-9)
        #expect(abs(placed[2]!.frame.midX - 150) < 1e-9 && abs(placed[2]!.frame.midY - 150) < 1e-9)
    }

    /// 离摆正 4° 以内吸住；按住 Shift 每 15° 一档
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

    /// 整组转过以后再转：按每张自己的角度吸正，不按这次转了多少
    @Test func snapsToUprightAfterEarlierTurns() {
        var turned = pair
        turned[1]!.rotation = .pi / 6
        turned[2]!.rotation = .pi / 6
        var r = Gesture.Rotate(origins: turned, box: Box(enclosing: Array(turned.values), rotation: .pi / 6), startAngle: 0)
        let at = { (deg: CGFloat) in CGPoint(x: r.box.center.x + 100 * cos(deg * .pi / 180), y: r.box.center.y + 100 * sin(deg * .pi / 180)) }
        r.turn(to: at(-27), steps: false)
        #expect(abs(r.turned + .pi / 6) < 1e-9)
        // 吸正以后框也是正的，读数是 0°
        #expect(abs(r.current.rotation) < 1e-9)
    }

    /// 转过的组框：按那个角度刚好包住整组
    @Test func rotatedGroupBoxHugsMembers() {
        let r = Gesture.Rotate(origins: pair, box: Box(enclosing: Array(pair.values)), startAngle: 0, turned: .pi / 4)
        let box = Box(enclosing: Array(r.placements.values), rotation: .pi / 4)
        #expect(abs(box.size.width - 300) < 1e-9 && abs(box.size.height - 100) < 1e-9)
        #expect(abs(box.center.x - 150) < 1e-9 && abs(box.center.y - 50) < 1e-9)
    }

    /// 角度各不相同的一组没法一起回正：不吸；Shift 时按转了多少每 15° 一档
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
