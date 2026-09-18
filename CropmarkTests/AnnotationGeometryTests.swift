import XCTest
@testable import Cropmark

/// 标注的命中与拖拽几何。全部用 stub 测量文字，不依赖 TextKit 的实际排版结果。
final class AnnotationGeometryTests: XCTestCase {
    /// 折行后固定 60 点宽、20 点高，与 maxWidth 脱钩，好验证"命中用的是折行宽度不是 maxWidth"
    let g = AnnotationGeometry { _, _, w in CGSize(width: min(w, 60), height: 20) }

    private func make(_ shape: Annotation.Shape, _ t: Thickness = .thin) -> Annotation {
        Annotation(shape: shape, style: Style(color: Palette.colors[0], thickness: t))
    }

    // MARK: 矩形

    /// 第一轮（描边优先）的判定：细线容差 6，边线外扩 6、内缩 6 夹出一条带子
    func testRectStrokeBandIsTheFirstPass() {
        let a = make(.rect(CGRect(x: 100, y: 100, width: 200, height: 100)))
        XCTAssertTrue(g.hitsStroke(a, at: CGPoint(x: 100, y: 100)), "角上")
        XCTAssertTrue(g.hitsStroke(a, at: CGPoint(x: 105, y: 150)), "左边线内侧")
        XCTAssertTrue(g.hitsStroke(a, at: CGPoint(x: 100, y: 95)), "上边线外侧还在容差里")
        XCTAssertFalse(g.hitsStroke(a, at: CGPoint(x: 150, y: 150)), "第一轮只认线，不认肚子")
        XCTAssertFalse(g.hitsStroke(a, at: CGPoint(x: 100, y: 93)), "超出容差")
    }

    /// 第二轮：矩形整块可点，像 PPT 选对象一样点哪选哪
    func testRectInteriorIsHittable() {
        let a = make(.rect(CGRect(x: 100, y: 100, width: 200, height: 100)))
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 150, y: 150)), "框内")
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 100, y: 100)), "边线")
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 100, y: 93)), "框外超出容差")
    }

    func testSmallRectIsSolidEvenForTheStrokePass() {
        // 10×10 的框内缩 6 之后内圈就没了，第一轮也整块算命中，否则小框根本点不着
        let a = make(.rect(CGRect(x: 100, y: 100, width: 10, height: 10)))
        XCTAssertTrue(g.hitsStroke(a, at: CGPoint(x: 105, y: 105)))
    }

    func testToleranceGrowsWithLineWidth() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let p = CGPoint(x: 93, y: 150)   // 离左边线 7 点
        XCTAssertTrue(g.hits(make(.rect(r), .thick), at: p), "粗线容差 8")
        XCTAssertFalse(g.hits(make(.rect(r), .thin), at: p), "细线容差 6")
    }

    // MARK: 椭圆

    func testEllipseStrokeRingIsTheFirstPass() {
        let a = make(.ellipse(CGRect(x: 100, y: 100, width: 100, height: 100)))
        XCTAssertTrue(g.hitsStroke(a, at: CGPoint(x: 150, y: 100)), "上顶点")
        XCTAssertTrue(g.hitsStroke(a, at: CGPoint(x: 205, y: 150)), "右顶点外侧仍在容差内")
        XCTAssertFalse(g.hitsStroke(a, at: CGPoint(x: 150, y: 150)), "圆心")
        XCTAssertFalse(g.hitsStroke(a, at: CGPoint(x: 150, y: 108)), "已经进到内圈里")
        XCTAssertFalse(g.hitsStroke(a, at: CGPoint(x: 208, y: 150)), "超出容差")
    }

    func testEllipseInteriorIsHittable() {
        let a = make(.ellipse(CGRect(x: 100, y: 100, width: 100, height: 100)))
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 150, y: 150)), "圆心也能选中")
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 208, y: 150)), "圆外还是不行")
    }

    func testFlatEllipseIsHittableNearItsFlatSide() {
        // 这条专门钉住"不要用从中心发射线求交点的近似"：
        // 400×40 的扁椭圆在 x=150 处，射线法会把距离高估好几倍，用户点不中曲线。
        // 判定的是第一轮，因为第二轮整块都命中，验不出这件事
        let a = make(.ellipse(CGRect(x: 0, y: 0, width: 400, height: 40)))
        XCTAssertTrue(g.hitsStroke(a, at: CGPoint(x: 150, y: 0.6)), "曲线上")
        XCTAssertFalse(g.hitsStroke(a, at: CGPoint(x: 150, y: 10)), "已经进到内部")
    }

    // MARK: 箭头

    func testArrowHitsShaftWithinTolerance() {
        let a = make(.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100)), .medium)
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 150, y: 105)), "距杆 5，容差 7")
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 150, y: 110)))
    }

    func testArrowHeadWingIsHittableBeyondShaftTolerance() {
        // 粗线的头部半宽 11.25，比容差 8 宽：只测线段会漏掉两个"翅膀"
        let a = make(.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100)), .thick)
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 176, y: 110)), "翅膀里")
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 176, y: 115)), "翅膀外")
    }

    // MARK: 画笔与马赛克

    func testPenHitsSegmentsNotTheChord() {
        // L 形笔迹：拐角内侧不该算命中，否则等于用首尾连线在判定
        let a = make(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]))
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 50, y: 3)))
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 103, y: 50)))
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 50, y: 50)), "拐角内侧")
    }

    func testSinglePointPenIsADot() {
        let a = make(.pen([CGPoint(x: 50, y: 50)]))
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 52, y: 52)))
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 70, y: 70)))
    }

    func testMosaicUsesBrushHalfWidth() {
        // 粗马赛克笔宽 32：命中区就是半宽 16，和渲染时的圆头描边严格一致，不额外加余量
        let a = make(.mosaic([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]), .thick)
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 50, y: 15)))
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 50, y: 18)))
    }

    // MARK: 文字

    func testTextHitUsesWrappedWidthNotMaxWidth() {
        // stub 折行成 60 点宽，而 maxWidth 是 200：右边那 140 点空白不该吃点击
        let a = make(.text("hi", origin: CGPoint(x: 10, y: 10), maxWidth: 200))
        XCTAssertTrue(g.hits(a, at: CGPoint(x: 15, y: 15)))
        XCTAssertFalse(g.hits(a, at: CGPoint(x: 100, y: 15)))
    }

    // MARK: 叠放顺序

    func testTopmostAnnotationWins() {
        let lower = make(.rect(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let upper = make(.rect(CGRect(x: 100, y: 100, width: 100, height: 100)))
        // 两条重合：不管点线上还是点肚子里，都拿到后画的那条，和渲染顺序一致
        XCTAssertEqual(g.topmost(at: CGPoint(x: 100, y: 150), in: [lower, upper])?.id, upper.id)
        XCTAssertEqual(g.topmost(at: CGPoint(x: 150, y: 150), in: [lower, upper])?.id, upper.id)
        XCTAssertNil(g.topmost(at: CGPoint(x: 400, y: 400), in: [lower, upper]), "谁都没碰到")
    }

    func testStrokeBeatsAreaWhenNested() {
        // "先标注细节、最后框个总的圈起来"是很常见的顺序。
        // 大矩形后画、整块又命中，如果不让描边先决胜负，它会把内部的箭头全吃掉
        let arrow = make(.arrow(from: CGPoint(x: 120, y: 150), to: CGPoint(x: 180, y: 150)))
        let ring = make(.rect(CGRect(x: 100, y: 100, width: 200, height: 100)))
        XCTAssertEqual(g.topmost(at: CGPoint(x: 150, y: 150), in: [arrow, ring])?.id, arrow.id, "点箭头杆拿到箭头")
        XCTAssertEqual(g.topmost(at: CGPoint(x: 100, y: 110), in: [arrow, ring])?.id, ring.id, "点大框的边拿到大框")
        XCTAssertEqual(g.topmost(at: CGPoint(x: 250, y: 130), in: [arrow, ring])?.id, ring.id, "点大框里的空白处拿到大框")
    }

    // MARK: 外接矩形

    func testBoundsCoverWhatIsActuallyDrawn() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(g.bounds(of: make(.rect(r))), r)
        // 笔迹外扩半个线宽
        XCTAssertEqual(g.bounds(of: make(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]))),
                       CGRect(x: -1, y: -1, width: 12, height: 12))
        // 马赛克外扩半个笔宽
        XCTAssertEqual(g.bounds(of: make(.mosaic([CGPoint(x: 0, y: 0)]), .thin)),
                       CGRect(x: -7, y: -7, width: 14, height: 14))
        // 箭头要含住头部三角，比线段本身宽
        let arrow = g.bounds(of: make(.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0)), .thick))
        XCTAssertLessThan(arrow.minY, -10, "头部翅膀伸出杆外")
    }

    // MARK: 把手

    func testArrowEndpointHandles() {
        let a = make(.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150)))
        XCTAssertEqual(g.handles(of: a).count, 2)
        XCTAssertEqual(g.handle(at: CGPoint(x: 100, y: 100), of: a), .start)
        XCTAssertEqual(g.handle(at: CGPoint(x: 200, y: 150), of: a), .end)
        XCTAssertNil(g.handle(at: CGPoint(x: 150, y: 125), of: a), "中点不是把手")
    }

    func testRectHasBoxHandlesAndFreeformHasNone() {
        XCTAssertEqual(g.handles(of: make(.rect(CGRect(x: 0, y: 0, width: 200, height: 100)))).count, 8)
        // 小矩形砍掉边中点，只剩四个角
        XCTAssertEqual(g.handles(of: make(.rect(CGRect(x: 0, y: 0, width: 20, height: 20)))).count, 4)
        XCTAssertTrue(g.handles(of: make(.pen([CGPoint(x: 0, y: 0)]))).isEmpty)
        XCTAssertTrue(g.handles(of: make(.mosaic([CGPoint(x: 0, y: 0)]))).isEmpty)
        XCTAssertTrue(g.handles(of: make(.text("x", origin: .zero, maxWidth: 50))).isEmpty)
    }

    // MARK: 平移

    func testMoveKeepsIdentityAndShape() {
        let a = make(.pen([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5)]))
        let moved = AnnotationGeometry.moved(a, by: CGVector(dx: 3, dy: -2))
        XCTAssertEqual(moved.id, a.id, "平移不该换一条新标注，否则撤销和选中都会指错人")
        guard case .pen(let pts) = moved.shape else { return XCTFail("not pen") }
        XCTAssertEqual(pts, [CGPoint(x: 3, y: -2), CGPoint(x: 13, y: 3)])
    }

    func testMoveClampsBoundingBoxToLimit() {
        let b = CGRect(x: 10, y: 10, width: 50, height: 50)
        let limit = CGRect(x: 0, y: 0, width: 100, height: 100)
        // 想右移 80，但右边只剩 40
        XCTAssertEqual(AnnotationGeometry.clampedOffset(CGVector(dx: 80, dy: 0), of: b, within: limit).dx, 40)
        XCTAssertEqual(AnnotationGeometry.clampedOffset(CGVector(dx: -80, dy: 0), of: b, within: limit).dx, -10)
    }

    func testOversizedAnnotationStillSlides() {
        // 标注比选区还大（选区后来被缩小过）：仍然可以在"盖住选区"的区间里滑，而不是被强行拉回
        let b = CGRect(x: -20, y: 0, width: 200, height: 10)
        let limit = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(AnnotationGeometry.clampedOffset(CGVector(dx: 5, dy: 0), of: b, within: limit).dx, 5)
        XCTAssertEqual(AnnotationGeometry.clampedOffset(CGVector(dx: 100, dy: 0), of: b, within: limit).dx, 20)
    }

    // MARK: 拉伸

    func testResizeFlipsAcrossTheOppositeCorner() {
        let a = make(.rect(CGRect(x: 100, y: 100, width: 200, height: 100)))
        let out = AnnotationGeometry.resized(a, handle: .box(.bottomRight), to: CGPoint(x: 50, y: 50), shift: false)
        guard case .rect(let r) = out.shape else { return XCTFail("not rect") }
        XCTAssertEqual(r, CGRect(x: 50, y: 50, width: 50, height: 50))
        XCTAssertEqual(out.id, a.id)
    }

    func testResizeClampsToMinSideInsteadOfDeleting() {
        // 拖到零尺寸不该让标注消失：选区那套"塌了就销毁"对标注是破坏性的
        let a = make(.rect(CGRect(x: 100, y: 100, width: 200, height: 100)), .medium)   // 线宽 4 → 最小边 4
        let out = AnnotationGeometry.resized(a, handle: .box(.bottomRight), to: CGPoint(x: 100, y: 100), shift: false)
        guard case .rect(let r) = out.shape else { return XCTFail("not rect") }
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 4, height: 4))
    }

    func testResizeEdgeHandleKeepsTheOtherDimension() {
        let a = make(.rect(CGRect(x: 100, y: 100, width: 200, height: 100)))
        let out = AnnotationGeometry.resized(a, handle: .box(.top), to: CGPoint(x: 999, y: 60), shift: false)
        guard case .rect(let r) = out.shape else { return XCTFail("not rect") }
        XCTAssertEqual(r, CGRect(x: 100, y: 60, width: 200, height: 140), "上边中点只改高度")
    }

    func testResizeArrowEndpointKeepsMinimumLength() {
        let a = make(.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100)))
        // 把终点拖到起点上：沿原方向撑到最小长度，而不是塌成一个点
        let out = AnnotationGeometry.resized(a, handle: .end, to: CGPoint(x: 100, y: 100), shift: false)
        guard case .arrow(let f, let t) = out.shape else { return XCTFail("not arrow") }
        XCTAssertEqual(f, CGPoint(x: 100, y: 100))
        XCTAssertEqual(hypot(t.x - f.x, t.y - f.y), AnnotationGeometry.minArrowLength, accuracy: 0.001)
    }

    func testResizeArrowStartMovesOnlyThatEnd() {
        let a = make(.arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100)))
        let out = AnnotationGeometry.resized(a, handle: .start, to: CGPoint(x: 40, y: 70), shift: false)
        guard case .arrow(let f, let t) = out.shape else { return XCTFail("not arrow") }
        XCTAssertEqual(f, CGPoint(x: 40, y: 70))
        XCTAssertEqual(t, CGPoint(x: 200, y: 100))
    }
}
