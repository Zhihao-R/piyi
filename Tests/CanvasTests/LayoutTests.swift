import Testing
import CoreGraphics
@testable import Canvas

@Suite struct LayoutTests {
    /// 自动分拣一张张放进来：排成几行，不摞成一竖条，彼此不压
    @Test func appendedCardsFillRowsInsteadOfOneColumn() {
        let size = CGSize(width: 240, height: 180)
        var placed: [CGRect] = []
        for _ in 0..<14 { placed.append(Layout.appended(size, to: placed)) }
        for (i, a) in placed.enumerated() { for b in placed[(i + 1)...] { #expect(!a.intersects(b)) } }
        let rows = Set(placed.map(\.minY)).count, bounds = placed.reduce(CGRect.null) { $0.union($1) }
        #expect(rows > 1 && rows < 14)
        #expect(bounds.width > bounds.height)
    }

    /// 接在最下面那一行的右边，不管上面的行有多宽
    @Test func appendedGoesRightOfTheLastRow() {
        let others = [CGRect(x: 0, y: 0, width: 900, height: 200), CGRect(x: 0, y: 220, width: 200, height: 200)]
        let next = Layout.appended(CGSize(width: 200, height: 200), to: others)
        #expect(next.minX >= 200 && next.minY == 220)
    }

    /// 粘贴：几张卡彼此的位置不变，整组中心落在指定点附近，压到已有的卡就整批往下让
    @Test func pastedCardsKeepTheirArrangement() {
        let frames = [CGRect(x: 1000, y: 1000, width: 200, height: 150), CGRect(x: 1220, y: 1040, width: 100, height: 100)]
        let free = Layout.around(CGPoint(x: 0, y: 0), frames: frames, avoiding: [])
        #expect(free[1].minX - free[0].minX == 220 && free[1].minY - free[0].minY == 40)
        #expect(abs(free.reduce(CGRect.null) { $0.union($1) }.midX) <= Grid.unit)
        let blocked = Layout.around(CGPoint(x: 0, y: 0), frames: frames, avoiding: [CGRect(x: -200, y: -200, width: 400, height: 400)])
        #expect(blocked[0].minY >= 200 && blocked[1].minX - blocked[0].minX == 220)
    }

    /// 资料库一行排多宽跟着可见区域走：窗口宽就多排，窄就少排，有上下限
    @Test func shelfWidthFollowsTheStage() {
        #expect(CanvasView.shelfWidth(for: 700) < CanvasView.shelfWidth(for: 1200))
        #expect(CanvasView.shelfWidth(for: 100) == Grid.unit * 40)
        #expect(CanvasView.shelfWidth(for: 5000) == Layout.shelfWidth)
    }
}
