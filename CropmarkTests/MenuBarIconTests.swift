import XCTest
import AppKit
@testable import Cropmark

@MainActor
final class MenuBarIconTests: XCTestCase {
    /// 按指定外观把菜单栏图标渲染成 2x 位图
    private func render(_ appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let px = Int(IconArtwork.menuBarSize) * 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = MenuBarIcon.make()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 某个区域里不透明像素的平均亮度，没有不透明像素返回 nil
    private func brightness(_ rep: NSBitmapImageRep, _ area: NSRect) -> CGFloat? {
        var sum: CGFloat = 0, n = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.3 else { continue }
                sum += (c.redComponent + c.greenComponent + c.blueComponent) / 3
                n += 1
            }
        }
        return n > 0 ? sum / CGFloat(n) : nil
    }

    /// 中间那块画面必须是彩色的，不能退化成灰
    func testPictureIsColorful() throws {
        let rep = try render(.aqua)
        let mid = Int(IconArtwork.menuBarSize)   // 36px 图的正中
        let c = try XCTUnwrap(rep.colorAt(x: mid, y: mid))
        XCTAssertGreaterThan(c.alphaComponent, 0.9, "画面中心是透明的")
        let spread = max(c.redComponent, c.greenComponent, c.blueComponent)
            - min(c.redComponent, c.greenComponent, c.blueComponent)
        XCTAssertGreaterThan(spread, 0.15, "画面中心不是彩色: \(c)")
    }

    /// 左上角那块只有括角、没有画面的区域。从共享几何反算，
    /// IconArtwork 的比例常量一改这里跟着走，不会变成过期的魔数。
    private var cornerOnlyArea: NSRect {
        let px = IconArtwork.menuBarSize * 2
        let frame = IconArtwork.menuBarFrame(in: CGRect(x: 0, y: 0, width: px, height: px))
        let picture = IconArtwork.pictureRect(in: frame)
        // 图形上下左右对称，所以位图坐标（y 从顶算）和这里的 CGRect 范围一致
        return NSRect(x: frame.minX, y: frame.minY,
                      width: picture.minX - frame.minX, height: picture.minY - frame.minY)
    }

    /// 不是 template 图标，所以括角得自己跟着深浅色反转
    func testCornersFollowAppearance() throws {
        let light = try XCTUnwrap(brightness(try render(.aqua), cornerOnlyArea), "浅色下左上角没画出括角")
        let dark = try XCTUnwrap(brightness(try render(.darkAqua), cornerOnlyArea), "深色下左上角没画出括角")
        XCTAssertLessThan(light, 0.4, "浅色菜单栏下括角应该是深色: \(light)")
        XCTAssertGreaterThan(dark, 0.6, "深色菜单栏下括角应该是浅色: \(dark)")
    }

    /// 浅色下括角必须就是应用图标那个 #2B2F3A，不能是别的深色。
    /// 曾经用过 NSColor.labelColor，那是接近纯黑的通用文字色，两个图标并不严格同色。
    func testLightModeCornersMatchAppIconInk() throws {
        let rep = try render(.aqua)
        // 取左上括角横臂正中间那一点，避开圆角端点的抗锯齿
        let arm = cornerOnlyArea
        let px = try XCTUnwrap(rep.colorAt(x: Int(arm.midX), y: Int(arm.minY + IconArtwork.menuBarLineWidth(
            in: CGRect(x: 0, y: 0, width: IconArtwork.menuBarSize * 2, height: IconArtwork.menuBarSize * 2)) / 2)))
        let ink = try XCTUnwrap(IconArtwork.inkColor.components)
        XCTAssertEqual(px.redComponent, ink[0], accuracy: 0.02, "括角红通道对不上应用图标: \(px)")
        XCTAssertEqual(px.greenComponent, ink[1], accuracy: 0.02, "括角绿通道对不上应用图标: \(px)")
        XCTAssertEqual(px.blueComponent, ink[2], accuracy: 0.02, "括角蓝通道对不上应用图标: \(px)")
    }

    /// 菜单栏图标和应用图标必须走同一套几何，画面占括角框的比例要一致
    func testSharesGeometryWithAppIcon() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pic = IconArtwork.pictureRect(in: frame)
        XCTAssertEqual(pic.width / frame.width, 1 - 2 * IconArtwork.pictureInsetRatio, accuracy: 0.001)
        // 菜单栏的括角框铺得比应用图标满：没有底板要让位，图形才立得住
        let menuFrame = IconArtwork.menuBarFrame(in: CGRect(x: 0, y: 0, width: 18, height: 18))
        XCTAssertEqual(menuFrame.width / 18, 16.0 / 18, accuracy: 0.001)
    }
}
