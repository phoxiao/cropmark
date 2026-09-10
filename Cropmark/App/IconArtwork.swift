import AppKit

/// 应用图标与菜单栏图标共用的几何与配色。
///
/// 两者是同一个图形的两个尺寸：都是「四个 L 括角 + 中间一块四色渐变画面」。
/// 差别只在配件和为小尺寸做的调整——应用图标多一块圆角底板和画面阴影，
/// 菜单栏图标去掉这些、把图形放大到铺满画布、并把线条按小尺寸加粗。
/// 所有比例都写在这里，改一处两边一起变，不会各画各的再慢慢漂移。
enum IconArtwork {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [
            CGFloat((h >> 16) & 0xff) / 255,
            CGFloat((h >> 8) & 0xff) / 255,
            CGFloat(h & 0xff) / 255, a,
        ])!
    }

    /// 画面的四色对角渐变：橙 → 黄 → 青 → 蓝
    static let pictureColors = [hex(0xFF7A59), hex(0xFFC53D), hex(0x4FD1C5), hex(0x5B7CFA)]
    /// 括角的深灰。浅色背景下两个图标用的都是它。
    static let inkColor = hex(0x2B2F3A)
    /// 深色背景下括角的对位色。inkColor 这个深灰糊在深色菜单栏里会看不见，
    /// 换成和底板同色系的浅色，比纯白柔和些。
    static let inkColorOnDark = hex(0xF2F4F8)
    static let plateTop = hex(0xFFFFFF)
    static let plateBottom = hex(0xE9ECF2)

    // 下面三个比例都相对「括角框」的边长，两个图标共用
    /// 每个 L 括角的臂长
    static let cornerArmRatio: CGFloat = 0.24
    /// 画面每边相对括角框内缩多少
    static let pictureInsetRatio: CGFloat = 0.14
    /// 画面圆角 / 画面边长
    static let pictureRadiusRatio: CGFloat = 0.0975

    /// 括角框里那块「画面」占的位置
    static func pictureRect(in frame: CGRect) -> CGRect {
        frame.insetBy(dx: frame.width * pictureInsetRatio, dy: frame.height * pictureInsetRatio)
    }

    /// 四个 L 括角
    static func drawCorners(_ c: CGContext, frame r: CGRect, lineWidth: CGFloat, color: CGColor) {
        let len = r.width * cornerArmRatio
        c.saveGState()
        c.setStrokeColor(color)
        c.setLineWidth(lineWidth)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        let arms: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: r.minX, y: r.maxY - len), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + len, y: r.maxY)),
            (CGPoint(x: r.maxX - len, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY - len)),
            (CGPoint(x: r.maxX, y: r.minY + len), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - len, y: r.minY)),
            (CGPoint(x: r.minX + len, y: r.minY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.minY + len)),
        ]
        for (a, b, d) in arms { c.move(to: a); c.addLine(to: b); c.addLine(to: d) }
        c.strokePath()
        c.restoreGState()
    }

    /// 括角框中间那块彩色画面。shadow 只有应用图标用，菜单栏那点尺寸投影看不出来。
    static func drawPicture(_ c: CGContext, frame r: CGRect, shadow: CGSize? = nil, blur: CGFloat = 0) {
        let pic = pictureRect(in: r)
        let radius = pic.width * pictureRadiusRatio
        let path = CGPath(roundedRect: pic, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let shadow {
            c.saveGState()
            c.setShadow(offset: shadow, blur: blur, color: hex(0x000000, 0.35))
            c.addPath(path); c.setFillColor(pictureColors[0]); c.fillPath()
            c.restoreGState()
        }
        c.saveGState()
        c.addPath(path); c.clip()
        let g = CGGradient(colorsSpace: sRGB, colors: pictureColors as CFArray, locations: nil)!
        c.drawLinearGradient(g, start: CGPoint(x: pic.minX, y: pic.maxY), end: CGPoint(x: pic.maxX, y: pic.minY), options: [])
        c.restoreGState()
    }

    /// 括角 + 画面，不带底板。这就是菜单栏图标的全部内容，也是应用图标的主体。
    static func drawGlyph(_ c: CGContext, frame r: CGRect, lineWidth: CGFloat, cornerColor: CGColor,
                          shadow: CGSize? = nil, blur: CGFloat = 0) {
        drawPicture(c, frame: r, shadow: shadow, blur: blur)
        drawCorners(c, frame: r, lineWidth: lineWidth, color: cornerColor)
    }

    // MARK: - 菜单栏图标

    /// 菜单栏图标的点尺寸
    static let menuBarSize: CGFloat = 18
    /// 菜单栏图标四周留白（点）
    static let menuBarMargin: CGFloat = 1

    /// 括角框：四周各留 1pt，图形铺满剩下的地方。
    /// 应用图标的括角框只占画布 62%（因为要给底板留边），菜单栏没有底板，
    /// 图形直接放大到 89%——这就是「同一个设计的更小版本」需要做的调整。
    static func menuBarFrame(in rect: CGRect) -> CGRect {
        // menuBarMargin 是按 18pt 定的，rect 可能是任意画布（@2x 就是 36px），先折算
        let margin = rect.width / menuBarSize * menuBarMargin
        return rect.insetBy(dx: margin, dy: margin)
    }

    /// 等比换算下来是 1.45pt，18pt 尺寸下太虚，加粗到 1.7pt 才立得住
    static func menuBarLineWidth(in rect: CGRect) -> CGFloat {
        rect.width / menuBarSize * 1.7
    }

    // MARK: - 应用图标

    /// 带圆角底板、描边和画面阴影的完整应用图标，画在 size×size 的画布上
    static func drawAppIcon(_ c: CGContext, canvas size: CGFloat) {
        // macOS 图标网格：1024 画布中图形占 824，圆角 22.5%
        let icon = CGRect(x: size * 100 / 1024, y: size * 100 / 1024,
                          width: size * 824 / 1024, height: size * 824 / 1024)
        let radius = icon.width * 0.225
        let shape = CGPath(roundedRect: icon, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 底：奶白到浅灰竖向渐变 + 细描边
        c.saveGState()
        c.addPath(shape); c.clip()
        let bg = CGGradient(colorsSpace: sRGB, colors: [plateTop, plateBottom] as CFArray, locations: nil)!
        c.drawLinearGradient(bg, start: CGPoint(x: 0, y: icon.maxY), end: CGPoint(x: 0, y: icon.minY), options: [])
        c.restoreGState()
        c.saveGState()
        c.addPath(shape)
        c.setStrokeColor(hex(0x000000, 0.08))
        c.setLineWidth(max(size * 0.006, 1))
        c.strokePath()
        c.restoreGState()

        let frame = icon.insetBy(dx: icon.width * 0.19, dy: icon.height * 0.19)
        drawGlyph(c, frame: frame, lineWidth: size * 0.045, cornerColor: inkColor,
                  shadow: CGSize(width: 0, height: -size * 0.02), blur: size * 0.05)
    }
}
