import XCTest
@testable import Clipper

/// 进程内走完一次截图交互：拖选 → 画矩形 → Enter → 剪贴板里有正确的图。
/// 覆盖窗不显示到屏幕上，只借它做坐标换算。
@MainActor
final class OverlayFlowTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var finished = false

    /// 400×300 点 @1x：左半红、右半蓝
    private func makeSnapshot(boundary: Int = 200) -> ScreenSnapshot {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: boundary, height: 300))
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 1, 1])!); ctx.fill(CGRect(x: boundary, y: 0, width: 400 - boundary, height: 300))
        return ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1, image: ctx.makeImage()!)
    }

    private func makeSession(windows: [LocatableWindow] = [], boundary: Int = 200) -> (CaptureSession, OverlayWindow, NSPasteboard) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.kivixiao.clipper.tests"))
        pb.clearContents()
        finished = false
        let snapshot = makeSnapshot(boundary: boundary)
        let session = CaptureSession(snapshots: [snapshot], windowList: windows) { [weak self] in self?.finished = true }
        session.pasteboard = pb
        let window = OverlayWindow(snapshot: snapshot, session: session)
        return (session, window, pb)
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
        XCTAssertNil(pb.data(forType: .png))
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
