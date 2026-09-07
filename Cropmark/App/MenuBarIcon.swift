import AppKit

/// 菜单栏模板图标：四个 L 括角 + 中间小方块，与应用图标同一语言。
enum MenuBarIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let r = rect.insetBy(dx: 1.5, dy: 1.5)
            let len: CGFloat = 4.5
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let corners: [(NSPoint, NSPoint, NSPoint)] = [
                (NSPoint(x: r.minX, y: r.maxY - len), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX + len, y: r.maxY)),
                (NSPoint(x: r.maxX - len, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY - len)),
                (NSPoint(x: r.maxX, y: r.minY + len), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX - len, y: r.minY)),
                (NSPoint(x: r.minX + len, y: r.minY), NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.minX, y: r.minY + len)),
            ]
            for (a, b, c) in corners { path.move(to: a); path.line(to: b); path.line(to: c) }
            NSColor.black.setStroke()
            path.stroke()
            let inner = r.insetBy(dx: 5, dy: 5)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
