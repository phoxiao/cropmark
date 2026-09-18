import XCTest
@testable import Cropmark

/// 画完的标注能再选中、再编辑：拉伸、拖动、删除、改样式、撤销重做。
@MainActor
final class AnnotationEditingTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// 挂在实例上由 tearDown 释放。比每个用例写一遍 defer withExtendedLifetime 可靠——
    /// 忘写一处，那个用例就会在会话提前释放时随机崩
    private var session: CaptureSession?

    override func tearDown() {
        session = nil
        super.tearDown()
    }

    /// 400×300 点 @1x 的白底屏幕
    private func makeSession() -> (OverlayWindow, NSPasteboard) {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let snapshot = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                      scale: 1, image: ctx.makeImage()!)
        let pb = NSPasteboard(name: NSPasteboard.Name("com.kivixiao.cropmark.tests.editing"))
        pb.clearContents()
        let session = CaptureSession(snapshots: [snapshot], windowList: [], elementDetection: .off) {}
        session.pasteboard = pb
        session.exportOptions = ExportOptions(copyAt1x: false, saveAt1x: false, clipboardIncludesFile: false)
        self.session = session
        return (session.makeWindows()[0], pb)
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in w: NSWindow,
                       flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: w.frame.height - p.y), modifierFlags: flags,
                           timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    private func key(_ code: UInt16, chars: String, flags: NSEvent.ModifierFlags = [], in w: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    private func drag(_ v: OverlayView, from a: CGPoint, to b: CGPoint, in w: NSWindow, flags: NSEvent.ModifierFlags = []) {
        v.mouseDown(with: mouse(.leftMouseDown, a, in: w, flags: flags))
        v.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), in: w, flags: flags))
        v.mouseDragged(with: mouse(.leftMouseDragged, b, in: w, flags: flags))
        v.mouseUp(with: mouse(.leftMouseUp, b, in: w, flags: flags))
    }
    private func click(_ v: OverlayView, at p: CGPoint, in w: NSWindow) {
        v.mouseDown(with: mouse(.leftMouseDown, p, in: w))
        v.mouseUp(with: mouse(.leftMouseUp, p, in: w))
    }
    /// AppKit 的双击是 down(1)/up(1)/down(2)/up(2)。只发一个裸的 clicks:2，
    /// "第一下做了什么"就完全测不出来
    private func doubleClick(_ v: OverlayView, at p: CGPoint, in w: NSWindow) {
        click(v, at: p, in: w)
        v.mouseDown(with: mouse(.leftMouseDown, p, in: w, clicks: 2))
        v.mouseUp(with: mouse(.leftMouseUp, p, in: w, clicks: 2))
    }

    /// 选区 (50,50)-(350,250)，里面画一个 (100,100)-(200,180) 的矩形，画完它是选中态
    private func withRect() -> (OverlayWindow, OverlayView) {
        let (window, _) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250), in: window)
        view.selectToolForTesting(.rect)
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180), in: window)
        return (window, view)
    }

    private func rect(_ view: OverlayView, _ i: Int = 0) -> CGRect? {
        guard i < view.annotationCount, case .rect(let r) = view.annotationsForTesting[i].shape else { return nil }
        return r
    }

    // MARK: 选中

    func testDrawingAutoSelectsTheNewAnnotation() {
        let (_, view) = withRect()
        XCTAssertEqual(view.annotationCount, 1)
        XCTAssertEqual(view.selectedAnnotationForTesting?.id, view.annotationsForTesting.first?.id,
                       "画完要立刻处于可调整状态，否则又得撤销重画")
    }

    func testClickingBlankSpaceDeselects() {
        let (window, view) = withRect()
        click(view, at: CGPoint(x: 300, y: 220), in: window)   // 选区内、标注外
        XCTAssertNil(view.selectedAnnotationForTesting)
    }

    func testClickingInsideARectSelectsIt() {
        let (window, view) = withRect()
        view.selectToolForTesting(nil)
        click(view, at: CGPoint(x: 300, y: 220), in: window)   // 先取消选中
        click(view, at: CGPoint(x: 150, y: 140), in: window)   // 框内任意位置
        XCTAssertEqual(view.selectedAnnotationForTesting?.id, view.annotationsForTesting.first?.id,
                       "点哪选哪。仍然能从框内起笔画新的，靠的是单击/拖动的区分，不是让框内不吃点击")
    }

    /// 用户报的那个 bug：画完框、在截图区域点一下、再点框，必须还能选中。
    /// 老代码里 select(nil) 在按下那一刻就执行了，而把选中还回来的 select(a.id)
    /// 藏在 endDrawing 的尺寸门槛之后——一次没位移的点击就成了纯粹的取消选中，不可逆
    func testClickingBlankThenTheRectSelectsItAgainWhileToolIsArmed() {
        let (window, view) = withRect()   // 矩形工具还亮着
        click(view, at: CGPoint(x: 300, y: 220), in: window)   // 选区内空白
        XCTAssertNil(view.selectedAnnotationForTesting)
        click(view, at: CGPoint(x: 150, y: 140), in: window)   // 回去点那个框
        XCTAssertEqual(view.selectedAnnotationForTesting?.id, view.annotationsForTesting.first?.id)
        XCTAssertEqual(view.annotationCount, 1, "单击不该顺手画出一条 0 尺寸的新标注")
    }

    func testDragStillDrawsAfterAClick() {
        let (window, view) = withRect()
        click(view, at: CGPoint(x: 150, y: 140), in: window)   // 点框内：选中
        drag(view, from: CGPoint(x: 250, y: 100), to: CGPoint(x: 300, y: 160), in: window)
        XCTAssertEqual(view.annotationCount, 2, "修了点选不能弄坏画新的")
    }

    func testTinyDragIsStillAClick() {
        let (window, view) = withRect()
        view.selectToolForTesting(nil)
        click(view, at: CGPoint(x: 300, y: 220), in: window)
        // 按下后只挪了 1 点就松手：算点选，不算拖动
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 140), in: window))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 151, y: 141), in: window))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 151, y: 141), in: window))
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 100, height: 80), "手抖不该把它挪走")
        XCTAssertEqual(view.selectedAnnotationForTesting?.id, view.annotationsForTesting.first?.id)
    }

    /// 画笔的"单击"本来就是落一个点，不该被点选机制吃掉
    func testPenClickStillCommitsADot() {
        let (window, _) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250), in: window)
        view.selectToolForTesting(.pen)
        click(view, at: CGPoint(x: 150, y: 140), in: window)
        XCTAssertEqual(view.annotationCount, 1)
        guard case .pen = view.annotationsForTesting[0].shape else { return XCTFail("not pen") }
    }

    /// 标注整块可点之后，一个盖住选区角的大框会让选区拉不动——
    /// 把手是画出来的白点，用户看得见就必须点得中
    func testSelectionHandleWinsOverAnAnnotationBodyCoveringIt() {
        let (window, _) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 200), in: window)
        view.selectToolForTesting(.rect)
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 250, y: 200), in: window)
        view.selectToolForTesting(nil)
        click(view, at: CGPoint(x: 60, y: 60), in: window)   // 取消选中，免得走标注把手那一支
        drag(view, from: CGPoint(x: 250, y: 200), to: CGPoint(x: 220, y: 170), in: window)
        XCTAssertEqual(view.currentSelection, CGRect(x: 50, y: 50, width: 170, height: 120), "拉的是选区")
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 150, height: 100), "标注一点没动")
        // 光标和点击必须说同一件事，否则它会承诺一件点下去不会发生的事
        XCTAssertFalse(view.cursorForTesting(at: CGPoint(x: 220, y: 170)) === NSCursor.openHand,
                       "选区把手上不该显示手形")
    }

    func testDoubleClickOnARectStillFinishes() {
        let (window, pb) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250), in: window)
        view.selectToolForTesting(.rect)
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 180), in: window)
        view.selectToolForTesting(nil)
        doubleClick(view, at: CGPoint(x: 150, y: 140), in: window)
        XCTAssertNotNil(pb.data(forType: .png), "双击完成截图不能因为标注盖住了就失灵")
    }

    func testDoubleClickWithAToolArmedDoesNotFinishTheSession() {
        let (window, pb) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250), in: window)
        view.selectToolForTesting(.pen)
        doubleClick(view, at: CGPoint(x: 150, y: 140), in: window)
        XCTAssertNil(pb.data(forType: .png), "画笔连点两下是点两个点，不是把会话结束掉")
        XCTAssertEqual(view.annotationCount, 2)
    }

    // MARK: 拉伸

    func testCornerDragResizesTheJustDrawnRectWhileToolIsStillArmed() {
        let (window, view) = withRect()
        // 矩形工具还亮着，从右下角起拖：拉的是刚画那条，不是画新的
        drag(view, from: CGPoint(x: 200, y: 180), to: CGPoint(x: 260, y: 220), in: window)
        XCTAssertEqual(view.annotationCount, 1)
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 160, height: 120))
    }

    func testToolStillDrawsWhenStartingOnAnOldAnnotationBorder() {
        let (window, view) = withRect()
        // 上边线上、离把手足够远的一点。工具亮着就该画新的——亮着的工具是个显式的模式声明
        drag(view, from: CGPoint(x: 125, y: 100), to: CGPoint(x: 160, y: 130), in: window)
        XCTAssertEqual(view.annotationCount, 2)
    }

    func testCommandClickSelectsAnnotationWhileToolIsArmed() {
        let (window, view) = withRect()
        click(view, at: CGPoint(x: 300, y: 220), in: window)   // 先取消选中
        // 工具还亮着，按住 ⌘ 让路：给"就是想改旧框"一个不用先关工具的出口
        drag(view, from: CGPoint(x: 125, y: 100), to: CGPoint(x: 145, y: 130), in: window, flags: .command)
        XCTAssertEqual(view.annotationCount, 1, "⌘ 点击改的是旧框，不该多出一条")
        XCTAssertEqual(rect(view), CGRect(x: 120, y: 130, width: 100, height: 80))
    }

    func testResizeClampsToMinSizeInsteadOfDeletingTheAnnotation() {
        let (window, view) = withRect()
        // 把右下角拖回左上角：钳到最小边长，而不是像选区那样塌了就销毁
        drag(view, from: CGPoint(x: 200, y: 180), to: CGPoint(x: 100, y: 100), in: window)
        XCTAssertEqual(view.annotationCount, 1, "手一抖不该无声删掉一条已经画好的标注")
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 4, height: 4))
    }

    // MARK: 拖动

    func testClickingAnAnnotationBorderSelectsAndDragsIt() {
        let (window, view) = withRect()
        view.selectToolForTesting(nil)
        drag(view, from: CGPoint(x: 125, y: 100), to: CGPoint(x: 145, y: 130), in: window)
        XCTAssertEqual(view.annotationCount, 1)
        XCTAssertEqual(rect(view), CGRect(x: 120, y: 130, width: 100, height: 80), "整体平移 (+20,+30)")
    }

    func testAnnotationCannotBeDraggedOutOfTheSelection() {
        let (window, view) = withRect()
        view.selectToolForTesting(nil)
        // 往上拖出天际：外接矩形贴住选区上沿就停住。
        // 拖出去的话它会被裁掉、看着像凭空消失，但其实还在，还占着 Delete 和 ⌘Z
        drag(view, from: CGPoint(x: 125, y: 100), to: CGPoint(x: 125, y: -500), in: window)
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 50, width: 100, height: 80))
    }

    // MARK: 删除

    func testDeleteRemovesTheSelectedAnnotation() {
        let (window, view) = withRect()
        drag(view, from: CGPoint(x: 250, y: 100), to: CGPoint(x: 300, y: 150), in: window)
        XCTAssertEqual(view.annotationCount, 2)
        view.keyDown(with: key(51, chars: "\u{8}", in: window))   // Delete
        XCTAssertEqual(view.annotationCount, 1)
        XCTAssertNil(view.selectedAnnotationForTesting)
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 100, height: 80), "删的是选中那条，不是最后一条")
    }

    // MARK: 撤销与重做

    func testUndoRestoresTheGeometryBeforeAResize() {
        let (window, view) = withRect()
        drag(view, from: CGPoint(x: 200, y: 180), to: CGPoint(x: 260, y: 220), in: window)
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 160, height: 120))
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertEqual(view.annotationCount, 1, "撤销的是这次拉伸，不是整条标注")
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 100, height: 80))
    }

    func testRedoReappliesTheResize() {
        let (window, view) = withRect()
        drag(view, from: CGPoint(x: 200, y: 180), to: CGPoint(x: 260, y: 220), in: window)
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertTrue(view.canRedoForTesting)
        view.keyDown(with: key(6, chars: "z", flags: [.command, .shift], in: window))
        XCTAssertEqual(rect(view), CGRect(x: 100, y: 100, width: 160, height: 120))
    }

    func testClickWithoutMovingDoesNotConsumeAnUndoStep() {
        let (window, view) = withRect()
        view.selectToolForTesting(nil)
        click(view, at: CGPoint(x: 125, y: 100), in: window)   // 按下即松开，什么都没动
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertEqual(view.annotationCount, 0, "空点击不该占掉一步撤销")
    }

    func testUndoClearsASelectionThatNoLongerExists() {
        let (window, view) = withRect()
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertEqual(view.annotationCount, 0)
        XCTAssertNil(view.selectedAnnotationForTesting, "撤销掉的那条不能还留着虚线框")
    }

    // MARK: 改样式

    func testStyleChangeAppliesToTheSelectedAnnotation() {
        let (window, view) = withRect()
        let blue = Style(color: Palette.colors[2], thickness: .thick)
        view.applyStyleForTesting(blue)
        XCTAssertEqual(view.annotationsForTesting.first?.style, blue)
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertEqual(view.annotationsForTesting.first?.style.thickness, .medium, "改样式也能撤回")
    }

    func testStyleChangeWithoutSelectionOnlyAffectsTheNextAnnotation() {
        let (window, view) = withRect()
        click(view, at: CGPoint(x: 300, y: 220), in: window)   // 取消选中
        view.applyStyleForTesting(Style(color: Palette.colors[2], thickness: .thick))
        XCTAssertEqual(view.annotationsForTesting.first?.style.thickness, .medium, "没选中就别动已有的")
    }

    // MARK: 重新框选

    func testReselectingClearsAnnotationsAndSelectionState() {
        let (window, view) = withRect()
        view.selectToolForTesting(nil)
        drag(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40), in: window)
        XCTAssertEqual(view.annotationCount, 0)
        XCTAssertNil(view.selectedAnnotationForTesting, "选中态必须跟着标注一起清，否则虚线框会画在空白处")
    }

    // MARK: 和选区把手抢地盘

    func testAnnotationHandleWinsOverTheSelectionHandleWhenTheyOverlap() {
        let (window, _) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 200), in: window)
        view.selectToolForTesting(.rect)
        // 标注的右下角正好压在选区的右下把手上
        drag(view, from: CGPoint(x: 150, y: 120), to: CGPoint(x: 250, y: 200), in: window)
        view.selectToolForTesting(nil)
        drag(view, from: CGPoint(x: 250, y: 200), to: CGPoint(x: 220, y: 170), in: window)
        XCTAssertEqual(view.currentSelection, CGRect(x: 50, y: 50, width: 200, height: 150), "选区不该被动到")
        XCTAssertEqual(rect(view), CGRect(x: 150, y: 120, width: 70, height: 50), "拉的是标注：选中标注的把手优先级最高")
    }

    // MARK: 导出

    func testResizedAnnotationExportsAtItsNewGeometry() throws {
        let (window, pb) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250), in: window)
        view.selectToolForTesting(.rect)
        view.applyStyleForTesting(Style(color: Palette.colors[2], thickness: .thick))
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 150), in: window)
        // 右下角拉到 (250,200)：导出图里矩形的新边线必须真的落在那儿
        drag(view, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 200), in: window)
        view.keyDown(with: key(36, chars: "\r", in: window))

        let img = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pb.data(forType: .png)))?.cgImage)
        XCTAssertEqual(img.width, 300)
        // 选区原点 (50,50)，所以矩形在导出图里是 (50,50)-(200,150)，线宽 6
        XCTAssertEqual(pixel(img, x: 197, y: 100)[2], 255, "新的右边线在这里")
        XCTAssertLessThan(pixel(img, x: 197, y: 100)[0], 120)
        XCTAssertEqual(pixel(img, x: 120, y: 100), [255, 255, 255], "框内还是白的，没被填充")
        XCTAssertEqual(pixel(img, x: 250, y: 100), [255, 255, 255], "旧的右边线位置应该已经空了")
        // 这条标注在 Enter 那一刻还是选中态，但虚线框和把手只是屏幕上的装饰，不该进导出图。
        // 虚线框在矩形外扩 3 点处，矩形边线只到 y=56，所以 y=47 那一行必须全白
        for x in 45...205 {
            XCTAssertEqual(pixel(img, x: x, y: 47), [255, 255, 255], "选中装饰漏进导出图了：x=\(x)")
        }
    }

    private func pixel(_ img: CGImage, x: Int, y: Int) -> [Int] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * img.width + x) * 4
        return [Int(p[i]), Int(p[i + 1]), Int(p[i + 2])]
    }
}


// MARK: - 文字标注的重新编辑

extension AnnotationEditingTests {
    /// 选区 (50,50)-(350,250)，在 (100,100) 写一条 "hello"，然后取消工具
    private func withText() throws -> (OverlayWindow, OverlayView) {
        let (window, _) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250), in: window)
        view.selectToolForTesting(.text)
        click(view, at: CGPoint(x: 100, y: 100), in: window)
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? TextEditorOverlay }.first)
        field.string = "hello"
        field.commit()
        view.selectToolForTesting(nil)
        return (window, view)
    }

    private func openEditor(_ view: OverlayView, at p: CGPoint, in window: NSWindow) throws -> TextEditorOverlay {
        doubleClick(view, at: p, in: window)
        return try XCTUnwrap(view.subviews.compactMap { $0 as? TextEditorOverlay }.first)
    }

    private func text(_ view: OverlayView) -> String? {
        guard view.annotationCount > 0, case .text(let s, _, _) = view.annotationsForTesting[0].shape else { return nil }
        return s
    }

    func testDoubleClickReopensCommittedTextWithItsContent() throws {
        let (window, view) = try withText()
        XCTAssertEqual(view.annotationCount, 1)
        let field = try openEditor(view, at: CGPoint(x: 110, y: 105), in: window)
        XCTAssertEqual(field.string, "hello", "重新打开要预填原文，而不是从空白开始")
        XCTAssertEqual(view.visibleAnnotationCountForTesting, 0, "原文要先藏起来，否则会和输入框里的字叠成重影")
    }

    func testEditingTextUpdatesInPlaceAndIsUndoable() throws {
        let (window, view) = try withText()
        let field = try openEditor(view, at: CGPoint(x: 110, y: 105), in: window)
        field.string = "world"
        field.commit()
        XCTAssertEqual(view.annotationCount, 1, "改的是原来那条，不是新增一条")
        XCTAssertEqual(text(view), "world")
        XCTAssertEqual(view.visibleAnnotationCountForTesting, 1, "提交后要重新画出来")
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertEqual(text(view), "hello")
    }

    func testClearingTextOnReEditDeletesTheAnnotation() throws {
        let (window, view) = try withText()
        let field = try openEditor(view, at: CGPoint(x: 110, y: 105), in: window)
        field.string = "  "
        field.commit()
        XCTAssertEqual(view.annotationCount, 0, "重编辑时清空内容就是删掉这一条")
        XCTAssertNil(view.selectedAnnotationForTesting)
    }

    func testEscapeDuringReEditKeepsTheOriginal() throws {
        let (window, view) = try withText()
        let field = try openEditor(view, at: CGPoint(x: 110, y: 105), in: window)
        field.string = "changed"
        field.keyDown(with: key(53, chars: "\u{1b}", in: window))
        XCTAssertEqual(text(view), "hello", "Esc 是放弃改动，不是删除")
        XCTAssertEqual(view.visibleAnnotationCountForTesting, 1)
    }

    func testEmptyNewTextLeavesNothingBehind() throws {
        let (window, _) = makeSession()
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 350, y: 250), in: window)
        view.selectToolForTesting(.text)
        click(view, at: CGPoint(x: 100, y: 100), in: window)
        let field = try XCTUnwrap(view.subviews.compactMap { $0 as? TextEditorOverlay }.first)
        field.commit()
        XCTAssertEqual(view.annotationCount, 0, "新建时什么都没打就提交，不该留下空标注")
    }

    func testTextCanBeDraggedAsAWhole() throws {
        let (window, view) = try withText()
        drag(view, from: CGPoint(x: 110, y: 105), to: CGPoint(x: 160, y: 145), in: window)
        guard case .text(_, let origin, _) = view.annotationsForTesting[0].shape else { return XCTFail("not text") }
        XCTAssertEqual(origin, CGPoint(x: 150, y: 140), "文字没有把手，但整条可以拖走")
    }
}
