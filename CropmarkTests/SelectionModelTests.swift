import XCTest
@testable import Cropmark

final class SelectionModelTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testDragProducesNormalizedRect() {
        var m = SelectionModel(bounds: bounds)
        m.mouseDown(at: CGPoint(x: 300, y: 200))
        m.mouseDragged(to: CGPoint(x: 100, y: 50))
        m.mouseUp(at: CGPoint(x: 100, y: 50))
        XCTAssertEqual(m.rect, CGRect(x: 100, y: 50, width: 200, height: 150))
        XCTAssertTrue(m.isSelected)
    }

    func testDragIsClampedToBounds() {
        var m = SelectionModel(bounds: bounds)
        m.mouseDown(at: CGPoint(x: 900, y: 500))
        m.mouseDragged(to: CGPoint(x: 1200, y: 800))
        m.mouseUp(at: CGPoint(x: 1200, y: 800))
        XCTAssertEqual(m.rect, CGRect(x: 900, y: 500, width: 100, height: 100))
    }

    func testPointsSnapToPixelGridAt2x() {
        var m = SelectionModel(bounds: bounds, scale: 2)
        m.mouseDown(at: CGPoint(x: 10.3, y: 10.3))
        m.mouseDragged(to: CGPoint(x: 110.6, y: 60.8))
        m.mouseUp(at: CGPoint(x: 110.6, y: 60.8))
        XCTAssertEqual(m.rect, CGRect(x: 10.5, y: 10.5, width: 100, height: 50.5))
        // 悬停窗口的边也要吸附
        var c = SelectionModel(bounds: bounds, scale: 2)
        c.hoverRect = CGRect(x: 10.2, y: 20.7, width: 100.1, height: 50.1)
        c.mouseDown(at: CGPoint(x: 50, y: 50))
        c.mouseUp(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(c.rect, CGRect(x: 10, y: 20.5, width: 100.5, height: 50.5))
    }

    func testClickPicksHoveredWindow() {
        var m = SelectionModel(bounds: bounds)
        m.hoverRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        m.mouseDown(at: CGPoint(x: 50, y: 50))
        m.mouseUp(at: CGPoint(x: 51, y: 50))
        XCTAssertEqual(m.rect, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertNil(m.hoverRect)
    }

    func testClickWithoutHoverSelectsWholeScreen() {
        var m = SelectionModel(bounds: bounds)
        m.mouseDown(at: CGPoint(x: 50, y: 50))
        m.mouseUp(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(m.rect, bounds)
    }

    private func selected(_ r: CGRect) -> SelectionModel {
        var m = SelectionModel(bounds: bounds)
        m.mouseDown(at: r.origin)
        m.mouseDragged(to: CGPoint(x: r.maxX, y: r.maxY))
        m.mouseUp(at: CGPoint(x: r.maxX, y: r.maxY))
        return m
    }

    func testCornerHandleResizes() {
        var m = selected(CGRect(x: 100, y: 100, width: 200, height: 100))
        m.mouseDown(at: CGPoint(x: 300, y: 200))   // bottomRight
        XCTAssertEqual(m.phase, .resizing(.bottomRight, opposite: CGPoint(x: 100, y: 100)))
        m.mouseDragged(to: CGPoint(x: 350, y: 260))
        m.mouseUp(at: CGPoint(x: 350, y: 260))
        XCTAssertEqual(m.rect, CGRect(x: 100, y: 100, width: 250, height: 160))
    }

    func testEdgeHandleChangesOnlyOneDimension() {
        var m = selected(CGRect(x: 100, y: 100, width: 200, height: 100))
        m.mouseDown(at: CGPoint(x: 200, y: 100))   // top
        m.mouseDragged(to: CGPoint(x: 260, y: 60))
        m.mouseUp(at: CGPoint(x: 260, y: 60))
        XCTAssertEqual(m.rect, CGRect(x: 100, y: 60, width: 200, height: 140))

        m.mouseDown(at: CGPoint(x: 100, y: 130))   // left
        m.mouseDragged(to: CGPoint(x: 80, y: 300))
        m.mouseUp(at: CGPoint(x: 80, y: 300))
        XCTAssertEqual(m.rect, CGRect(x: 80, y: 60, width: 220, height: 140))
    }

    func testHandleCrossOverFlipsRect() {
        var m = selected(CGRect(x: 100, y: 100, width: 200, height: 100))
        m.mouseDown(at: CGPoint(x: 300, y: 200))
        m.mouseDragged(to: CGPoint(x: 50, y: 50))
        m.mouseUp(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(m.rect, CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    func testMoveStaysInsideBounds() {
        var m = selected(CGRect(x: 100, y: 100, width: 200, height: 100))
        m.mouseDown(at: CGPoint(x: 150, y: 150))
        m.mouseDragged(to: CGPoint(x: 1050, y: 700))
        m.mouseUp(at: CGPoint(x: 1050, y: 700))
        XCTAssertEqual(m.rect, CGRect(x: 800, y: 500, width: 200, height: 100))
    }

    func testClickOutsideSelectionStartsNewDrag() {
        var m = selected(CGRect(x: 100, y: 100, width: 200, height: 100))
        m.mouseDown(at: CGPoint(x: 600, y: 400))
        XCTAssertEqual(m.phase, .dragging(anchor: CGPoint(x: 600, y: 400)))
        XCTAssertNil(m.rect)
    }

    func testTinySelectionCanStillBeMoved() {
        // 20×20 的选区上，把手命中半径收缩到约 6.7，中心留得出空档，
        // 否则四个角的命中区会把内部铺满，小选区就只能拉伸、永远拖不动
        var m = selected(CGRect(x: 100, y: 100, width: 20, height: 20))
        m.mouseDown(at: CGPoint(x: 110, y: 110))
        XCTAssertEqual(m.phase, .moving(grabOffset: CGPoint(x: 10, y: 10)))
    }

    func testHandleHitTolerance() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionModel.handle(at: CGPoint(x: 100, y: 100), of: r), .topLeft)
        XCTAssertEqual(SelectionModel.handle(at: CGPoint(x: 309, y: 150), of: r), .right)
        XCTAssertNil(SelectionModel.handle(at: CGPoint(x: 200, y: 150), of: r))
    }
}

final class ToolbarPlacementTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let size = CGSize(width: 300, height: 36)

    func testBelowSelectionRightAligned() {
        let f = ToolbarPlacement.frame(selection: CGRect(x: 100, y: 100, width: 400, height: 200), size: size, bounds: bounds)
        XCTAssertEqual(f, CGRect(x: 200, y: 308, width: 300, height: 36))
    }
    func testAboveWhenNoRoomBelow() {
        let f = ToolbarPlacement.frame(selection: CGRect(x: 100, y: 400, width: 400, height: 190), size: size, bounds: bounds)
        XCTAssertEqual(f.maxY, 392)
    }
    func testInsideWhenNoRoomEither() {
        let f = ToolbarPlacement.frame(selection: bounds, size: size, bounds: bounds)
        XCTAssertEqual(f.maxY, 592)
        XCTAssertEqual(f.maxX, 1000)
    }
    func testClampedToLeftEdge() {
        let f = ToolbarPlacement.frame(selection: CGRect(x: 0, y: 0, width: 100, height: 100), size: size, bounds: bounds)
        XCTAssertEqual(f.minX, 0)
    }
}


final class HandleLayoutTests: XCTestCase {
    func testNearestHandleWinsOnOverlap() {
        // 20×20 的矩形上，右中点和右下角的命中区必然重叠。
        // 按 allCases 顺序取会先撞上 .right，用户点了右下角却只能改宽不能改高。
        let r = CGRect(x: 100, y: 100, width: 20, height: 20)
        XCTAssertEqual(HandleLayout.handle(at: CGPoint(x: 120, y: 120), of: r), .bottomRight)
        XCTAssertEqual(HandleLayout.handle(at: CGPoint(x: 100, y: 120), of: r), .bottomLeft)
    }

    func testEdgeHandlesDroppedOnShortSides() {
        XCTAssertEqual(HandleLayout.handles(of: CGRect(x: 0, y: 0, width: 200, height: 100)).count, 8)
        // 高度 20 撑不开左右中点：它俩会被上下两个角吃掉
        let flat = HandleLayout.handles(of: CGRect(x: 0, y: 0, width: 200, height: 20))
        XCTAssertEqual(flat.count, 6)
        XCTAssertFalse(flat.contains(.left) || flat.contains(.right))
        XCTAssertTrue(flat.contains(.top) && flat.contains(.bottom))
        XCTAssertEqual(HandleLayout.handles(of: CGRect(x: 0, y: 0, width: 20, height: 20)).count, 4)
    }

    func testHitRadiusShrinksWithSize() {
        XCTAssertEqual(HandleLayout.hitRadius(of: CGRect(x: 0, y: 0, width: 200, height: 100)), 10)
        XCTAssertEqual(HandleLayout.hitRadius(of: CGRect(x: 0, y: 0, width: 20, height: 20)), 20.0 / 3, accuracy: 0.001)
        XCTAssertEqual(HandleLayout.hitRadius(of: CGRect(x: 0, y: 0, width: 6, height: 6)), 3)
    }

    func testOppositeMatchesTheFarSide() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(HandleLayout.opposite(.topLeft, in: r), CGPoint(x: 300, y: 200))
        XCTAssertEqual(HandleLayout.opposite(.bottomRight, in: r), CGPoint(x: 100, y: 100))
        XCTAssertEqual(HandleLayout.opposite(.top, in: r), CGPoint(x: 100, y: 200))
        XCTAssertEqual(HandleLayout.opposite(.left, in: r), CGPoint(x: 300, y: 100))
    }

    func testLiveHandleFlipsAcrossTheOpposite() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let o = HandleLayout.opposite(.bottomRight, in: r)
        XCTAssertEqual(HandleLayout.live(.bottomRight, in: r, opposite: o), .bottomRight)
        // 拖过左上角之后，手里抓的其实是左上角那个把手了
        let flipped = CGRect(x: 50, y: 50, width: 50, height: 50)
        XCTAssertEqual(HandleLayout.live(.bottomRight, in: flipped, opposite: o), .topLeft)
        // 边中点只翻它自己那一维
        let top = HandleLayout.opposite(.top, in: r)
        XCTAssertEqual(HandleLayout.live(.top, in: r, opposite: top), .top)
        XCTAssertEqual(HandleLayout.live(.top, in: CGRect(x: 100, y: 200, width: 200, height: 50), opposite: top), .bottom)
    }

    func testResizeKeepsMinSideWithoutMovingTheAnchor() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        // 右下角拖回固定点：撑成 4×4，左上角纹丝不动
        let o1 = HandleLayout.opposite(.bottomRight, in: r)
        XCTAssertEqual(HandleLayout.resized(r, handle: .bottomRight, to: CGPoint(x: 100, y: 100), opposite: o1, minSide: 4),
                       CGRect(x: 100, y: 100, width: 4, height: 4))
        // 左上角拖回固定点：往左上撑，右下角不动
        let o2 = HandleLayout.opposite(.topLeft, in: r)
        XCTAssertEqual(HandleLayout.resized(r, handle: .topLeft, to: CGPoint(x: 300, y: 200), opposite: o2, minSide: 4),
                       CGRect(x: 296, y: 196, width: 4, height: 4))
        // 上边中点只该管高度，宽度原样保留
        let o3 = HandleLayout.opposite(.top, in: r)
        XCTAssertEqual(HandleLayout.resized(r, handle: .top, to: CGPoint(x: 150, y: 200), opposite: o3, minSide: 4),
                       CGRect(x: 100, y: 196, width: 200, height: 4))
    }

    func testResizeWithoutMinSideStillCollapses() {
        // 选区走的是这条：拖到零尺寸就该塌掉，由 mouseUp 判成"取消选区"
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let o = HandleLayout.opposite(.bottomRight, in: r)
        XCTAssertEqual(HandleLayout.resized(r, handle: .bottomRight, to: CGPoint(x: 100, y: 100), opposite: o),
                       CGRect(x: 100, y: 100, width: 0, height: 0))
    }
}
