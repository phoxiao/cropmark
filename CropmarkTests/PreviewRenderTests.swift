import XCTest
@testable import Cropmark

/// 把覆盖层离屏渲染成 PNG（~/Library/Caches/CropmarkBuild/preview-*.png），供人工/agent 看外观。
@MainActor
final class PreviewRenderTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func gradientSnapshot() -> ScreenSnapshot {
        let w = 1200, h = 800
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(colorSpace: sRGB, components: [0.95, 0.85, 0.6, 1])!, CGColor(colorSpace: sRGB, components: [0.4, 0.6, 0.9, 1])!]
        let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 300, y: 200, width: 500, height: 350))   // 模拟一个白色窗口
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.2, 0.2, 0.2, 1])!)
        for i in 0..<8 { ctx.fill(CGRect(x: 330, y: 500 - i * 36, width: 300 - i * 20, height: 12)) }  // 模拟文字行
        return ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 600, height: 400), scale: 2, image: ctx.makeImage()!)
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in w: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: w.frame.height - p.y), modifierFlags: [], timestamp: 0,
                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func drag(_ v: OverlayView, _ a: CGPoint, _ b: CGPoint, in w: NSWindow) {
        v.mouseDown(with: mouse(.leftMouseDown, a, in: w))
        v.mouseDragged(with: mouse(.leftMouseDragged, b, in: w))
        v.mouseUp(with: mouse(.leftMouseUp, b, in: w))
    }


    func testRenderOverlayStates() throws {
        let snap = gradientSnapshot()
        let session = CaptureSession(snapshots: [snap], windowList: [LocatableWindow(frame: CGRect(x: 150, y: 125, width: 250, height: 175), pid: 1)]) {}
        defer { withExtendedLifetime(session) {} }
        let window = session.makeWindows()[0]
        let view = window.overlayView
        // 底图在独立的一层，要渲染整个内容视图才能连底图一起看到
        let canvas = try XCTUnwrap(window.contentView)

        // 1) 悬停识别窗口
        view.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 250, y: 150), in: window))
        try savePreview(canvas, "preview-1-hover.png")

        // 2) 拖选后：把手 + 尺寸 + 工具栏
        drag(view, CGPoint(x: 120, y: 80), CGPoint(x: 480, y: 330), in: window)
        try savePreview(canvas, "preview-2-selected.png")

        // 3) 标注：矩形、箭头、画笔、马赛克、文字，工具栏展开颜色面板
        view.selectToolForTesting(.rect)
        drag(view, CGPoint(x: 160, y: 110), CGPoint(x: 300, y: 200), in: window)
        view.selectToolForTesting(.arrow)
        drag(view, CGPoint(x: 320, y: 300), CGPoint(x: 420, y: 150), in: window)
        view.selectToolForTesting(.pen)
        drag(view, CGPoint(x: 150, y: 280), CGPoint(x: 260, y: 310), in: window)
        view.selectToolForTesting(.mosaic)
        drag(view, CGPoint(x: 180, y: 240), CGPoint(x: 280, y: 240), in: window)
        view.selectToolForTesting(.ellipse)
        try savePreview(canvas, "preview-3-annotated.png")

        // 导出结果
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        let img = try XCTUnwrap(session.lastImage)
        XCTAssertEqual(img.width, 720)   // 360pt × 2
        XCTAssertEqual(img.height, 500)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/CropmarkBuild")
        try XCTUnwrap(Exporter.pngData(img, scale: 2)).write(to: dir.appendingPathComponent("preview-4-export.png"))
    }
}
