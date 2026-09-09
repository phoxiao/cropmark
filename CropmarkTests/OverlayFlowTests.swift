import XCTest
@testable import Cropmark

/// 进程内走完一次截图交互：拖选 → 画矩形 → Enter → 剪贴板里有正确的图。
/// 覆盖窗不显示到屏幕上，只借它做坐标换算。
@MainActor
final class OverlayFlowTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var finished = false
    private var focusReturned = false

    /// 400×300 点 @1x：左半红、右半蓝
    private func makeSnapshot(boundary: Int = 200) -> ScreenSnapshot {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: boundary, height: 300))
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 1, 1])!); ctx.fill(CGRect(x: boundary, y: 0, width: 400 - boundary, height: 300))
        return ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1, image: ctx.makeImage()!)
    }

    private func makeSession(windows: [LocatableWindow] = [], boundary: Int = 200) -> (CaptureSession, OverlayWindow, NSPasteboard) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.kivixiao.cropmark.tests"))
        pb.clearContents()
        finished = false
        focusReturned = false
        let snapshot = makeSnapshot(boundary: boundary)
        let session = CaptureSession(snapshots: [snapshot], windowList: windows,
                                     returnFocus: { [weak self] in self?.focusReturned = true }) { [weak self] in self?.finished = true }
        session.pasteboard = pb
        session.exportOptions = ExportOptions(copyAt1x: false, saveAt1x: false, clipboardIncludesFile: false)
        let window = session.makeWindows()[0]
        return (session, window, pb)
    }

    /// 两块并排的屏幕：第一屏 (0,0) 400×300，第二屏 (400,0) 400×300。
    private func makeTwoScreenSession(windows: [LocatableWindow] = []) -> (CaptureSession, [OverlayWindow]) {
        let s1 = makeSnapshot()
        let s2 = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 400, y: 0, width: 400, height: 300), scale: 1, image: s1.image)
        let session = CaptureSession(snapshots: [s1, s2], windowList: windows) {}
        return (session, session.makeWindows())
    }

    // 视图坐标（左上原点）→ 窗口坐标（左下原点）
    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in w: NSWindow, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let loc = CGPoint(x: p.x, y: w.frame.height - p.y)
        return NSEvent.mouseEvent(with: type, location: loc, modifierFlags: flags, timestamp: 0, windowNumber: w.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
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

    private func pixel(_ img: CGImage, x: Int, y: Int) -> [Int] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * img.width + x) * 4
        return [Int(p[i]), Int(p[i + 1]), Int(p[i + 2])]
    }

    /// Retina 屏幕的尺寸标签：默认标全分辨率 @2x，开了「复制时缩到 1x」就标缩小后的尺寸 @1x
    func testSizeLabelReflectsRetinaOutput() {
        let base = makeSnapshot().image   // 400×300 px，当作 2x 屏就是 200×150 pt
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 200, height: 150), scale: 2, image: base)
        let session = CaptureSession(snapshots: [snap], windowList: []) {}
        session.exportOptions = ExportOptions(copyAt1x: false, saveAt1x: false, clipboardIncludesFile: false)
        let view = session.makeWindows()[0].overlayView
        let r = CGRect(x: 10, y: 10, width: 101, height: 50)
        XCTAssertEqual(view.sizeLabelText(for: r), "202 × 100 @2x")
        session.exportOptions.copyAt1x = true
        XCTAssertEqual(view.sizeLabelText(for: r), "101 × 50 @1x")
        withExtendedLifetime(session) {}

        // 非 Retina：不带后缀
        let (s1, w1, _) = makeSession()
        XCTAssertEqual(w1.overlayView.sizeLabelText(for: CGRect(x: 0, y: 0, width: 50, height: 20)), "50 × 20")
        withExtendedLifetime(s1) {}
    }

    func testDragSelectAnnotateAndCopy() throws {
        let (session, window, pb) = makeSession()
        let view = window.overlayView

        drag(view, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 250), in: window)
        XCTAssertEqual(view.currentSelection, CGRect(x: 100, y: 50, width: 200, height: 200))
        XCTAssertTrue(view.isToolbarVisible)
        XCTAssertTrue(session.activeView === view)

        // 选矩形工具，在选区内画一个 (150,100)-(250,200) 的矩形（默认红色、中等粗细 4pt）
        view.selectToolForTesting(.rect)
        drag(view, from: CGPoint(x: 150, y: 100), to: CGPoint(x: 250, y: 200), in: window)
        XCTAssertEqual(view.annotationCount, 1)

        // Enter 完成
        view.keyDown(with: key(36, chars: "\r", in: window))
        XCTAssertTrue(finished)
        XCTAssertTrue(focusReturned, "focus must go back to the app the user was using")
        withExtendedLifetime(session) {}

        let data = try XCTUnwrap(pb.data(forType: .png))
        let img = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
        XCTAssertEqual(img.width, 200)
        XCTAssertEqual(img.height, 200)
        XCTAssertEqual(pixel(img, x: 5, y: 5), [255, 0, 0])       // 左：红底
        XCTAssertEqual(pixel(img, x: 195, y: 195), [0, 0, 255])   // 右：蓝底
        // 矩形左边线在导出图 x=50..54 处（选区相对坐标），取 x=52,y=100 应为标注色
        let stroke = pixel(img, x: 52, y: 100)
        XCTAssertGreaterThan(stroke[0], 200)
        XCTAssertLessThan(stroke[2], 120)
        XCTAssertNotEqual(stroke, [255, 0, 0])
        XCTAssertNotNil(pb.data(forType: .tiff))
    }

    func testUndoRemovesAnnotation() {
        let (session, window, _) = makeSession()
        defer { withExtendedLifetime(session) {} }
        let view = window.overlayView
        drag(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 390, y: 290), in: window)
        view.selectToolForTesting(.arrow)
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 120), in: window)
        view.selectToolForTesting(.pen)
        drag(view, from: CGPoint(x: 60, y: 200), to: CGPoint(x: 220, y: 260), in: window)
        XCTAssertEqual(view.annotationCount, 2)
        view.keyDown(with: key(6, chars: "z", flags: .command, in: window))
        XCTAssertEqual(view.annotationCount, 1)
    }

    func testClickPicksHoveredWindowAndEscCancels() {
        let win = LocatableWindow(frame: CGRect(x: 40, y: 60, width: 120, height: 80), pid: getpid())  // 本进程的窗口也要能识别；AppKit 坐标，屏幕高 300
        let (session, window, pb) = makeSession(windows: [win])
        defer { withExtendedLifetime(session) {} }
        let view = window.overlayView
        // 视图坐标 (100,200) 对应屏幕坐标 (100,100)，落在该窗口内
        view.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 100, y: 200), in: window))
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 200), in: window))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 100, y: 200), in: window))
        // 窗口 y 60..140（向上）→ 视图 y 160..240
        XCTAssertEqual(view.currentSelection, CGRect(x: 40, y: 160, width: 120, height: 80))

        view.keyDown(with: key(53, chars: "\u{1b}", in: window))
        XCTAssertTrue(finished)
        XCTAssertTrue(focusReturned)
        XCTAssertNil(pb.data(forType: .png))
    }

    func testUnhandledKeyIsSwallowedAndCapsLockUndoWorks() {
        let (session, window, _) = makeSession()
        defer { withExtendedLifetime(session) {} }
        let view = window.overlayView
        drag(view, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 390, y: 290), in: window)
        view.selectToolForTesting(.pen)
        drag(view, from: CGPoint(x: 60, y: 200), to: CGPoint(x: 220, y: 260), in: window)
        view.keyDown(with: key(0, chars: "a", in: window))   // 随便一个键，不能崩也不该有副作用
        XCTAssertEqual(view.annotationCount, 1)
        XCTAssertEqual(view.currentSelection, CGRect(x: 10, y: 10, width: 380, height: 280))
        view.keyDown(with: key(6, chars: "Z", flags: .command, in: window))   // 大写锁定下的 ⌘Z
        XCTAssertEqual(view.annotationCount, 0)
    }

    func testCursorFollowsSelectionState() {
        let (session, window, _) = makeSession()
        defer { withExtendedLifetime(session) {} }
        let view = window.overlayView
        XCTAssertTrue(view.cursorForTesting(at: CGPoint(x: 50, y: 50)) === NSCursor.crosshair)
        drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200), in: window)
        XCTAssertTrue(view.cursorForTesting(at: CGPoint(x: 150, y: 150)) === NSCursor.openHand, "inside selection: move")
        XCTAssertTrue(view.cursorForTesting(at: CGPoint(x: 50, y: 50)) === NSCursor.crosshair, "outside: new selection")
        let corner = view.cursorForTesting(at: CGPoint(x: 300, y: 200))
        XCTAssertFalse(corner === NSCursor.openHand || corner === NSCursor.crosshair, "handle: resize cursor")
        view.selectToolForTesting(.text)
        XCTAssertTrue(view.cursorForTesting(at: CGPoint(x: 150, y: 150)) === NSCursor.iBeam)
        XCTAssertTrue(view.cursorForTesting(at: CGPoint(x: 50, y: 50)) === NSCursor.crosshair)
        view.selectToolForTesting(.rect)
        XCTAssertTrue(view.cursorForTesting(at: CGPoint(x: 150, y: 150)) === NSCursor.crosshair)
        XCTAssertTrue(view.cursorForTesting(at: CGPoint(x: 300, y: 200)) === NSCursor.crosshair, "tools disable handles")
    }

    // MARK: 多屏

    func testSecondScreenSelectionMakesFirstBystanderAndRightClickClears() {
        // 第二屏上有一个窗口：AppKit 坐标 (500,100) 100×50 → 第二屏视图坐标 (100,150) 100×50
        let win = LocatableWindow(frame: CGRect(x: 500, y: 100, width: 100, height: 50), pid: 1)
        let (session, windows) = makeTwoScreenSession(windows: [win])
        defer { withExtendedLifetime(session) {} }
        let (v1, v2) = (windows[0].overlayView, windows[1].overlayView)

        v2.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 150, y: 170), in: windows[1]))
        v2.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 170), in: windows[1]))
        v2.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 170), in: windows[1]))
        XCTAssertEqual(v2.currentSelection, CGRect(x: 100, y: 150, width: 100, height: 50))
        XCTAssertTrue(v1.isBystander)
        XCTAssertFalse(v2.isBystander)

        // 旁观屏幕上左键无效
        drag(v1, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100), in: windows[0])
        XCTAssertNil(v1.currentSelection)
        XCTAssertEqual(v2.currentSelection, CGRect(x: 100, y: 150, width: 100, height: 50))

        // 旁观屏幕上右键：清掉第二屏的选区，两屏都回到可框选状态，而不是取消整个会话
        v1.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 10, y: 10), in: windows[0]))
        XCTAssertNil(v2.currentSelection)
        XCTAssertFalse(v2.isToolbarVisible)
        XCTAssertFalse(v1.isBystander)
        XCTAssertFalse(v2.isBystander)
        XCTAssertFalse(session.windows.isEmpty, "session must still be alive")

        drag(v1, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100), in: windows[0])
        XCTAssertEqual(v1.currentSelection, CGRect(x: 10, y: 10, width: 90, height: 90))
        XCTAssertTrue(v2.isBystander)
    }

    func testResizingToZeroClearsSelectionAndBystanders() {
        let (session, windows) = makeTwoScreenSession()
        defer { withExtendedLifetime(session) {} }
        let (v1, v2) = (windows[0].overlayView, windows[1].overlayView)
        drag(v1, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), in: windows[0])
        v1.selectToolForTesting(.rect)
        drag(v1, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180), in: windows[0])
        v1.selectToolForTesting(nil)
        XCTAssertEqual(v1.annotationCount, 1)
        XCTAssertTrue(v2.isBystander)
        // 把右下把手拖到左上角，选区变成零尺寸
        drag(v1, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 100, y: 100), in: windows[0])
        XCTAssertNil(v1.currentSelection)
        XCTAssertFalse(v1.isToolbarVisible)
        XCTAssertEqual(v1.annotationCount, 0)
        XCTAssertFalse(v2.isBystander, "other screens must leave bystander mode when the selection collapses")
    }

    func testTextToolWrapsAtSelectionEdgeAndExports() throws {
        let (session, window, pb) = makeSession()
        defer { withExtendedLifetime(session) {} }
        let view = window.overlayView
        drag(view, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 250), in: window)
        view.selectToolForTesting(.text)
        // 在 x=200 落笔，到选区右边 250 只剩 50 点宽，"Cropmark Cropmark" 必须折成多行
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 200, y: 100), in: window))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 100), in: window))
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? TextEditorOverlay }.first)
        XCTAssertEqual(editor.maxWidth, 50)
        editor.string = "Cropmark Cropmark"
        editor.commit()
        XCTAssertEqual(view.annotationCount, 1)
        XCTAssertTrue(view.subviews.compactMap { $0 as? TextEditorOverlay }.isEmpty, "editor should be removed after commit")
        guard case .text(let s, let origin, let maxWidth, _) = try XCTUnwrap(view.annotationsForTesting.first) else { return XCTFail("not text") }
        XCTAssertEqual(s, "Cropmark Cropmark")
        XCTAssertEqual(origin, CGPoint(x: 200, y: 100))
        XCTAssertEqual(maxWidth, 50)

        view.keyDown(with: key(36, chars: "\r", in: window))
        let img = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pb.data(forType: .png)))?.cgImage)
        // 底图 x≥200 是蓝色，文字默认红色。若没折行，第一行（约 22 点高）以下全是蓝；折行后第二行开始也应出现红色像素
        var foundBelowFirstLine = false
        for y in 75..<150 where !foundBelowFirstLine {
            for x in 150..<200 {
                let p = pixel(img, x: x, y: y)
                if p[0] > 150 && p[2] < 120 { foundBelowFirstLine = true; break }
            }
        }
        XCTAssertTrue(foundBelowFirstLine, "wrapped text should paint red pixels below the first line")
    }

    func testMosaicChangesPixelsInsideBrush() throws {
        // 红蓝边界放在 x=193：中等粗细块边长 10，块 190..200 的中心 195 落在蓝色里，
        // 所以块化后 x=191 这一列应从红变蓝；远离笔迹处不变。
        let (session, window, pb) = makeSession(boundary: 193)
        defer { withExtendedLifetime(session) {} }
        let view = window.overlayView
        drag(view, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 300), in: window)
        view.selectToolForTesting(.mosaic)
        drag(view, from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 150), in: window)
        XCTAssertEqual(view.annotationCount, 1)
        view.keyDown(with: key(36, chars: "\r", in: window))
        let img = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pb.data(forType: .png)))?.cgImage)
        XCTAssertEqual(img.width, 400)
        XCTAssertEqual(pixel(img, x: 191, y: 20), [255, 0, 0], "far from brush must stay red")
        let onBrush = pixel(img, x: 191, y: 150)
        XCTAssertNotEqual(onBrush, [255, 0, 0], "pixel on the brush should be pixelated: \(onBrush)")
    }
}

@MainActor
final class ToolbarPanelTests: XCTestCase {
    /// 选中马赛克时只有粗细一行，但这一行必须算进面板高度，否则悬在面板外点不到。
    func testMosaicOptionRowStaysInsidePanel() {
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        let tb = ToolbarPanel()
        host.contentView?.addSubview(tb)
        let collapsed = tb.preferredSize.height
        for tool in ToolKind.allCases {
            tb.selectTool(tool)
            XCTAssertEqual(tb.preferredSize.height, collapsed + ToolbarPanel.optionRowHeight, "\(tool)")
            tb.frame = CGRect(origin: .zero, size: tb.preferredSize)
            tb.layoutSubtreeIfNeeded()
            for row in tb.subviews where !row.isHidden {
                XCTAssertTrue(tb.bounds.contains(row.frame), "\(tool): row \(row.frame) outside panel \(tb.bounds)")
            }
        }
        tb.selectTool(nil)
        XCTAssertEqual(tb.preferredSize.height, collapsed)
    }
}

@MainActor
final class CaptureCoordinatorTests: XCTestCase {
    private final class Probe {
        var grabCount = 0
        var release: CheckedContinuation<Void, Never>?
    }

    private func spin(until cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { await Task.yield() }
        XCTAssertTrue(cond(), "condition not reached")
    }

    /// 抓屏还没返回时再按一次快捷键必须被忽略，否则会留下一层关不掉的遮罩。
    func testSecondBeginDuringGrabIsIgnored() async {
        let probe = Probe()
        let coordinator = CaptureCoordinator(ensurePermission: { true }) {
            probe.grabCount += 1
            await withCheckedContinuation { probe.release = $0 }
            throw CancellationError()   // 不真正开会话，避免测试里弹出全屏覆盖窗
        }
        coordinator.begin()
        coordinator.begin()
        XCTAssertTrue(coordinator.isBusy)
        await spin { probe.release != nil }
        XCTAssertEqual(probe.grabCount, 1)

        probe.release?.resume()
        probe.release = nil
        await spin { !coordinator.isBusy }
        XCTAssertEqual(probe.grabCount, 1)

        // 结束后可以重新开始
        coordinator.begin()
        await spin { probe.release != nil }
        XCTAssertEqual(probe.grabCount, 2)
        probe.release?.resume()
        await spin { !coordinator.isBusy }
    }

    func testPermissionDeniedDoesNotGrab() async {
        let probe = Probe()
        let coordinator = CaptureCoordinator(ensurePermission: { false }) {
            probe.grabCount += 1
            throw CancellationError()
        }
        coordinator.begin()
        XCTAssertFalse(coordinator.isBusy)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.grabCount, 0)
    }
}
