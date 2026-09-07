import XCTest
@testable import Cropmark

final class WindowLocatorTests: XCTestCase {
    func testCGToAppKitFlipsY() {
        let r = WindowLocator.cgToAppKit(CGRect(x: 10, y: 20, width: 100, height: 50), primaryHeight: 1000)
        XCTAssertEqual(r, CGRect(x: 10, y: 930, width: 100, height: 50))
    }

    func testTopmostWinsIncludingOwnProcessWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let windows = [
            LocatableWindow(frame: CGRect(x: 100, y: 100, width: 200, height: 200), pid: getpid()),  // 本应用的设置窗口，最前
            LocatableWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 800), pid: 8),
        ]
        XCTAssertEqual(WindowLocator.topmostWindow(at: CGPoint(x: 150, y: 150), in: windows, clampTo: screen),
                       CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(WindowLocator.topmostWindow(at: CGPoint(x: 500, y: 500), in: windows, clampTo: screen),
                       CGRect(x: 0, y: 0, width: 800, height: 800))
        XCTAssertNil(WindowLocator.topmostWindow(at: CGPoint(x: 900, y: 900), in: windows, clampTo: screen))
    }

    func testWindowClampedToScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let windows = [LocatableWindow(frame: CGRect(x: 900, y: 900, width: 300, height: 300), pid: 1)]
        XCTAssertEqual(WindowLocator.topmostWindow(at: CGPoint(x: 950, y: 950), in: windows, clampTo: screen),
                       CGRect(x: 900, y: 900, width: 100, height: 100))
    }
}

final class ArrowGeometryTests: XCTestCase {
    func testHeadPointsRightForHorizontalArrow() {
        let g = ArrowGeometry.build(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), lineWidth: 4)
        XCTAssertEqual(g.head[0], CGPoint(x: 100, y: 0))
        XCTAssertEqual(g.shaftEnd.y, 0, accuracy: 0.001)
        XCTAssertLessThan(g.shaftEnd.x, 100)
        XCTAssertEqual(g.head[1].x, g.head[2].x, accuracy: 0.001)
        XCTAssertEqual(g.head[1].y, -g.head[2].y, accuracy: 0.001)
    }

    func testShortArrowHeadNotLongerThanShaft() {
        let g = ArrowGeometry.build(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 5, y: 0), lineWidth: 6)
        XCTAssertGreaterThanOrEqual(g.shaftEnd.x, 0)
    }

    func testSnapTo45Degrees() {
        let to = ArrowGeometry.snapped(from: .zero, to: CGPoint(x: 100, y: 10))
        XCTAssertEqual(to.x, 100.499, accuracy: 0.01)
        XCTAssertEqual(to.y, 0, accuracy: 0.001)
        let diag = ArrowGeometry.snapped(from: .zero, to: CGPoint(x: 100, y: 90))
        XCTAssertEqual(diag.x, diag.y, accuracy: 0.001)
    }

    func testSquareKeepsAnchor() {
        let r = CGRect.square(anchor: CGPoint(x: 100, y: 100), drag: CGPoint(x: 40, y: 130))
        XCTAssertEqual(r, CGRect(x: 40, y: 100, width: 60, height: 60))
    }
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, 1])!
}

final class MosaicTests: XCTestCase {
    private func solidImage(w: Int, h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(srgb(1, 0, 0))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(srgb(0, 0, 1))
        ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        return ctx.makeImage()!
    }

    func testPixelateKeepsSize() {
        let img = solidImage(w: 64, h: 48)
        let out = Mosaic.pixelate(img, blockPixels: 8)
        XCTAssertEqual(out?.width, 64)
        XCTAssertEqual(out?.height, 48)
    }
}

final class ImageComposerTests: XCTestCase {
    func testPixelRectScalesAndClamps() {
        let r = ImageComposer.pixelRect(for: CGRect(x: 10.4, y: 20.2, width: 100, height: 50), scale: 2, imageSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(r, CGRect(x: 20, y: 40, width: 201, height: 101))  // integral 向外取整
        let clipped = ImageComposer.pixelRect(for: CGRect(x: 150, y: 100, width: 100, height: 100), scale: 2, imageSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(clipped, CGRect(x: 300, y: 200, width: 100, height: 100))
    }

    func testComposeCropsCorrectRegionAt2x() {
        // 400×300 像素图：左半红、右半蓝；屏幕 200×150 点，scale 2
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(srgb(1, 0, 0)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        ctx.setFillColor(srgb(0, 0, 1)); ctx.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        // 顶部 20 像素涂绿，用来验证 y 方向没有翻转
        ctx.setFillColor(srgb(0, 1, 0)); ctx.fill(CGRect(x: 0, y: 280, width: 400, height: 20))
        let base = ctx.makeImage()!
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 200, height: 150), scale: 2, image: base)
        let renderer = AnnotationRenderer(screenSize: CGSize(width: 200, height: 150)) { _ in nil }

        // 选区：视图坐标 x 50..150（跨红蓝边界），y 0..20（含顶部绿条）
        let out = ImageComposer.compose(snapshot: snap, selection: CGRect(x: 50, y: 0, width: 100, height: 20), annotations: [], renderer: renderer)!
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 40)
        XCTAssertEqual(pixel(out, x: 10, y: 30), [255, 0, 0])   // 左下：红
        XCTAssertEqual(pixel(out, x: 190, y: 30), [0, 0, 255])  // 右下：蓝
        XCTAssertEqual(pixel(out, x: 10, y: 5), [0, 255, 0])    // 顶部：绿
    }

    func testAnnotationLandsAtSelectionRelativePosition() {
        let w = 100, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let base = ctx.makeImage()!
        let snap = ScreenSnapshot(screen: NSScreen.screens[0], frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1, image: base)
        let renderer = AnnotationRenderer(screenSize: CGSize(width: 100, height: 100)) { _ in nil }
        let style = Style(color: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), thickness: .thick)
        // 选区 (20,20)-(80,80)；在视图坐标 (30..50, 30..50) 画实心一样粗的矩形
        let out = ImageComposer.compose(snapshot: snap, selection: CGRect(x: 20, y: 20, width: 60, height: 60),
                                        annotations: [.rect(CGRect(x: 30, y: 30, width: 20, height: 20), style)], renderer: renderer)!
        XCTAssertEqual(out.width, 60)
        // 矩形左上角在导出图里应落在 (10,10) 附近，线宽 6 → (10..16) 是蓝
        XCTAssertEqual(pixel(out, x: 12, y: 12), [0, 0, 255])
        XCTAssertEqual(pixel(out, x: 40, y: 40), [255, 255, 255])  // 矩形中心不填充
        XCTAssertEqual(pixel(out, x: 2, y: 2), [255, 255, 255])
    }

    /// 读取 (x, y) 像素的 RGB，y 从顶部数
    private func pixel(_ img: CGImage, x: Int, y: Int) -> [Int] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * img.width + x) * 4
        return [Int(p[i]), Int(p[i + 1]), Int(p[i + 2])]
    }
}
