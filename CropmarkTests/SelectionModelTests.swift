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
