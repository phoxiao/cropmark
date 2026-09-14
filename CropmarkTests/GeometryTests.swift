import XCTest
import ScreenCaptureKit
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

    /// Dock 在 20 层、窗口铺满整块屏幕并排在所有应用之前，放进来的话每次悬停都只会选中它。
    /// 菜单栏（24）、状态栏（25）、工具提示（200）同理。
    func testUnwantedLayersAreFilteredOut() {
        func info(layer: Int, onscreen: Bool = true) -> [String: Any] {
            [kCGWindowLayer as String: layer,
             kCGWindowOwnerPID as String: pid_t(42),
             kCGWindowIsOnscreen as String: onscreen,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 400, height: 300)
                .dictionaryRepresentation as NSDictionary]
        }
        for rejected in [20, 24, 25, 102, 200, 500, -2147483601] {
            XCTAssertNil(WindowLocator.locatable(from: info(layer: rejected), primaryHeight: 1000),
                         "layer \(rejected) 不该被识别")
        }
        for accepted in [0, 3, 8, 19, 101] {
            XCTAssertNotNil(WindowLocator.locatable(from: info(layer: accepted), primaryHeight: 1000),
                            "layer \(accepted) 应该被识别")
        }
        XCTAssertNil(WindowLocator.locatable(from: info(layer: 0, onscreen: false), primaryHeight: 1000))
    }

    func testWindowClampedToScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let windows = [LocatableWindow(frame: CGRect(x: 900, y: 900, width: 300, height: 300), pid: 1)]
        XCTAssertEqual(WindowLocator.topmostWindow(at: CGPoint(x: 950, y: 950), in: windows, clampTo: screen),
                       CGRect(x: 900, y: 900, width: 100, height: 100))
    }
}

final class ElementGeometryTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 400, height: 300)

    func testAcceptsARectInsideTheWindow() {
        let dialog = CGRect(x: 180, y: 160, width: 200, height: 140)
        XCTAssertEqual(ElementGeometry.refine(window: window, element: dialog), dialog)
    }

    func testNilElementFallsBackToWholeWindow() {
        XCTAssertEqual(ElementGeometry.refine(window: window, element: nil), window)
    }

    /// 算出来的矩形不在窗口里，只可能是坐标换算写反了（y 翻转是重灾区），必须退回整窗
    func testRectOutsideTheWindowIsRejected() {
        XCTAssertEqual(ElementGeometry.refine(window: window, element: CGRect(x: 480, y: 160, width: 200, height: 140)),
                       window)
        XCTAssertEqual(ElementGeometry.refine(window: window, element: .zero), window)
    }
}

final class BlockDetectorTests: XCTestCase {
    /// 造一张图：dim 色的底 + 一块 card 色的矩形，可选在卡片里再画几行"文字"
    private func canvas(size: Int = 400, card: PixelRect, dim: UInt8 = 90, cardColor: UInt8 = 245,
                        text: Bool = false) -> LumaBuffer {
        var px = [UInt8](repeating: dim, count: size * size)
        for y in card.y0...card.y1 {
            for x in card.x0...card.x1 { px[y * size + x] = cardColor }
        }
        if text {
            for row in stride(from: card.y0 + 20, to: card.y1 - 20, by: 24) {
                for y in row..<min(row + 8, card.y1) {
                    for x in (card.x0 + 15)...(card.x1 - 15) { px[y * size + x] = 40 }
                }
            }
        }
        return LumaBuffer(width: size, height: size, pixels: px)
    }

    private var whole: PixelRect { PixelRect(x0: 0, y0: 0, x1: 399, y1: 399) }

    private func assertFound(_ found: PixelRect?, matches card: PixelRect,
                             tolerance: Int = 2, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try XCTUnwrap(found, file: file, line: line)
        for (a, b) in [(r.x0, card.x0), (r.x1, card.x1), (r.y0, card.y0), (r.y1, card.y1)] {
            XCTAssertLessThanOrEqual(abs(a - b), tolerance, "\(r) 对不上 \(card)", file: file, line: line)
        }
    }

    func testFindsACardOnDimmedBackground() throws {
        let card = PixelRect(x0: 100, y0: 80, x1: 300, y1: 260)
        try assertFound(BlockDetector.rect(at: (x: 200, y: 170), in: canvas(card: card), bounds: whole),
                        matches: card)
    }

    /// 关键用例：光标压在卡片里的文字上，也要找到整张卡片而不是那一行文字。
    /// 这正是"向外扫描找第一条边"那套做法翻车的地方。
    func testTextInsideTheCardDoesNotTrapTheDetector() throws {
        let card = PixelRect(x0: 100, y0: 80, x1: 300, y1: 260)
        let buf = canvas(card: card, text: true)
        try assertFound(BlockDetector.rect(at: (x: 200, y: 124), in: buf, bounds: whole), matches: card)
    }

    /// 光标落在卡片外的蒙层上：会一路长满整屏，必须判为无结果而不是把整屏当选区
    func testSeedOnTheDimmedBackdropYieldsNothing() {
        let card = PixelRect(x0: 100, y0: 80, x1: 300, y1: 260)
        XCTAssertNil(BlockDetector.rect(at: (x: 30, y: 30), in: canvas(card: card), bounds: whole))
    }

    func testPlainBackgroundYieldsNothing() {
        let flat = LumaBuffer(width: 400, height: 400, pixels: [UInt8](repeating: 120, count: 160000))
        XCTAssertNil(BlockDetector.rect(at: (x: 200, y: 200), in: flat, bounds: whole))
    }

    func testTinyBlockIsRejected() {
        let chip = PixelRect(x0: 190, y0: 190, x1: 210, y1: 210)
        XCTAssertNil(BlockDetector.rect(at: (x: 200, y: 200), in: canvas(card: chip), bounds: whole))
    }

    /// 细长条不像一个"块"：外接矩形撑得很大但填充率很低，应当被否掉
    func testLShapedRegionIsRejectedByFillRatio() {
        var px = [UInt8](repeating: 90, count: 400 * 400)
        for y in 100...300 { for x in 100...120 { px[y * 400 + x] = 245 } }   // 竖条
        for x in 100...300 { for y in 280...300 { px[y * 400 + x] = 245 } }   // 横条
        let buf = LumaBuffer(width: 400, height: 400, pixels: px)
        XCTAssertNil(BlockDetector.rect(at: (x: 110, y: 150), in: buf, bounds: whole))
    }
}

/// 钉住 AppKit 屏幕坐标（y 向上）和图像像素（y 向下）之间的换算。
/// 翻转写反了高亮会跑到对称的另一半去，而且合成图单测发现不了——所以单独测一遍。
final class BlockLocatorTests: XCTestCase {
    /// 400x300 像素的图：暗底 + 一块亮卡片，卡片在图上占 x 80..279、从顶部数第 60..159 行
    private func image() -> CGImage {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.35, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(gray: 0.96, alpha: 1)
        // CGContext 是左下原点：顶部第 60 行、高 100 行 → y = 300 - 60 - 100
        ctx.fill(CGRect(x: 80, y: 140, width: 200, height: 100))
        return ctx.makeImage()!
    }

    func testPixelBlockMapsBackToScreenCoordinates() throws {
        // 屏幕在 AppKit 里位于 (100,50)，200x150 点，2 倍分辨率 → 正好 400x300 像素
        let screen = CGRect(x: 100, y: 50, width: 200, height: 150)
        let locator = BlockLocator(image: image(), screenFrame: screen, scale: 2, step: 1)
        // 图上 (180,110) → 屏幕内偏移 (90 点, 距顶 55 点) → AppKit (190, 145)
        let found = try XCTUnwrap(locator.element(at: CGPoint(x: 190, y: 145), within: screen))
        // 卡片：x 从 140 起宽 100；距顶 30 点、高 50 点 → AppKit y 从 120 起
        let expected = CGRect(x: 140, y: 120, width: 100, height: 50)
        XCTAssertLessThanOrEqual(abs(found.frame.minX - expected.minX), 2, "\(found.frame)")
        XCTAssertLessThanOrEqual(abs(found.frame.minY - expected.minY), 2, "\(found.frame)")
        XCTAssertLessThanOrEqual(abs(found.frame.width - expected.width), 2, "\(found.frame)")
        XCTAssertLessThanOrEqual(abs(found.frame.height - expected.height), 2, "\(found.frame)")
    }

    func testPointOutsideTheScreenYieldsNothing() {
        let screen = CGRect(x: 100, y: 50, width: 200, height: 150)
        let locator = BlockLocator(image: image(), screenFrame: screen, scale: 2, step: 1)
        XCTAssertNil(locator.element(at: CGPoint(x: 10, y: 10), within: screen))
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

final class ExporterTests: XCTestCase {
    private func solid(w: Int, h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Retina 截图要按点尺寸声明 DPI，粘到尊重 DPI 的应用里才不会显示成两倍大
    func testRetinaExportDeclaresPointSize() throws {
        let img = solid(w: 100, h: 60)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Exporter.pngData(img, scale: 2))))
        XCTAssertEqual(png.pixelsWide, 100)
        XCTAssertEqual(png.pixelsHigh, 60)
        XCTAssertEqual(png.size.width, 50, accuracy: 0.1)
        XCTAssertEqual(png.size.height, 30, accuracy: 0.1)

        let pb = NSPasteboard(name: NSPasteboard.Name("com.kivixiao.cropmark.tests.exporter"))
        Exporter.copyToPasteboard(img, scale: 2, to: pb)
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(pb.data(forType: .tiff))))
        XCTAssertEqual(tiff.size.width, 50, accuracy: 0.1)

        let plain = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Exporter.pngData(img))))
        XCTAssertEqual(plain.size.width, 100, accuracy: 0.1)
    }
}

@MainActor
final class CaptureFailureTests: XCTestCase {
    func testUserDeclinedCountsAsPermissionProblem() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertEqual(CaptureCoordinator.failure(for: declined), .permission)
        XCTAssertNotEqual(CaptureCoordinator.failure(for: ScreenGrabError.noDisplays), .permission)
        let generic = NSError(domain: "x", code: 1)
        if case .other(let msg) = CaptureCoordinator.failure(for: generic) {
            // 文案随系统语言变，只检查系统的错误描述被完整带上、且模板确实包了一层
            XCTAssertTrue(msg.contains(generic.localizedDescription), msg)
            XCTAssertGreaterThan(msg.count, generic.localizedDescription.count, msg)
        } else { XCTFail("generic error should map to .other") }
    }
}

final class TextLayoutTests: XCTestCase {
    func testNarrowWidthWrapsIntoMoreLines() {
        let style = Style(color: .black, thickness: .medium)
        let attr = AnnotationRenderer.attributedText("Cropmark Cropmark Cropmark", style: style)
        let wide = AnnotationRenderer.textRect(attr, origin: .zero, maxWidth: 1000)
        let narrow = AnnotationRenderer.textRect(attr, origin: .zero, maxWidth: 90)
        XCTAssertEqual(narrow.width, 90)
        XCTAssertGreaterThan(narrow.height, wide.height * 1.9, "narrow \(narrow) should be at least two lines vs \(wide)")
    }
}

final class ImageComposerTests: XCTestCase {
    func testPixelRectScalesAndClamps() {
        let r = ImageComposer.pixelRect(for: CGRect(x: 10.4, y: 20.2, width: 100, height: 50), scale: 2, imageSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(r, CGRect(x: 21, y: 40, width: 200, height: 100))  // 四条边各自四舍五入，宽高不会多 1 像素
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

final class DownscaleAndClipboardFileTests: XCTestCase {
    private func gradient(w: Int, h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
        return ctx.makeImage()!
    }

    /// 2x 缩到 1x：长宽减半，并按 1x 声明（点尺寸 = 像素尺寸）
    func testDownscaleHalvesRetinaAndDeclares1x() throws {
        let img = gradient(w: 200, h: 120)
        let out = Exporter.output(img, scale: 2, at1x: true)
        XCTAssertEqual(out.image.width, 100)
        XCTAssertEqual(out.image.height, 60)
        XCTAssertEqual(out.scale, 1)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Exporter.pngData(out.image, scale: out.scale))))
        XCTAssertEqual(png.size.width, 100, accuracy: 0.1)
        // 奇数像素四舍五入，不会掉成 0
        XCTAssertEqual(Exporter.output(gradient(w: 3, h: 3), scale: 2, at1x: true).image.width, 2)
        // 非 Retina 或没开缩放：原图原样
        XCTAssertTrue(Exporter.output(img, scale: 1, at1x: true).image === img)
        XCTAssertTrue(Exporter.output(img, scale: 2, at1x: false).image === img)
    }

    /// 剪贴板同一项里同时有 PNG、TIFF 和文件 URL；文件真的在磁盘上，且只保留最近几张
    func testClipboardCarriesImageAndFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cropmark-clip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.kivixiao.cropmark.tests.clipfile"))
        let img = gradient(w: 40, h: 30)

        Exporter.copyToPasteboard(img, scale: 1, includeFile: true, fileDirectory: dir, to: pb)
        let items = try XCTUnwrap(pb.pasteboardItems)
        XCTAssertEqual(items.count, 1, "一个 item 带三种类型，而不是三个 item")
        XCTAssertEqual(items[0].types.prefix(2), [.png, .tiff], "图片类型排在文件前面，要图的应用优先拿到图")
        XCTAssertTrue(items[0].types.contains(.fileURL))
        let urls = try XCTUnwrap(pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        let file = try XCTUnwrap(urls.first)
        // 文件名前缀随语言（截屏 / Screenshot），只检查扩展名和日期部分
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertNotNil(file.lastPathComponent.range(of: #"\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}"#, options: .regularExpression), file.lastPathComponent)
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: file))?.pixelsWide, 40)

        // 关掉附带文件：只有图片
        Exporter.copyToPasteboard(img, scale: 1, includeFile: false, fileDirectory: dir, to: pb)
        XCTAssertFalse(try XCTUnwrap(pb.pasteboardItems)[0].types.contains(.fileURL))
        XCTAssertNotNil(pb.data(forType: .png))

        // 同一秒内连截多张不覆盖，超过保留数的旧文件被清掉
        let png = try XCTUnwrap(Exporter.pngData(img))
        for _ in 0..<5 { XCTAssertNotNil(Exporter.writeClipboardFile(png, in: dir, keep: 3)) }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(left.count, 3)
    }
}
