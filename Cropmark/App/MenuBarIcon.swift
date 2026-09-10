import AppKit

/// 菜单栏图标：和应用图标同一套几何（见 IconArtwork），去掉底板、按小尺寸加粗线条。
enum MenuBarIcon {
    static func make() -> NSImage {
        let size = NSSize(width: IconArtwork.menuBarSize, height: IconArtwork.menuBarSize)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            IconArtwork.drawGlyph(c,
                                  frame: IconArtwork.menuBarFrame(in: rect),
                                  lineWidth: IconArtwork.menuBarLineWidth(in: rect),
                                  cornerColor: cornerColor)
            return true
        }
        // 中间画面是彩色的，不能当 template 用（那会被系统抹成纯单色）。
        // 代价是括角得自己适配深浅色：关掉缓存，每次绘制重新判一次外观。
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }

    /// 浅色菜单栏下就是应用图标那个深灰，两者严格同色；深色下换成它的浅色对位。
    /// 不用 labelColor：那是接近纯黑的通用文字色，和应用图标的 #2B2F3A 差一截。
    private static var cornerColor: CGColor {
        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? IconArtwork.inkColorOnDark : IconArtwork.inkColor
    }
}
