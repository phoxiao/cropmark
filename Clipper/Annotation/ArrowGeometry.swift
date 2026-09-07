import CoreGraphics

/// 箭头几何（纯函数）。
enum ArrowGeometry {
    /// 箭头头部长度和半宽随线宽增长
    static func headLength(lineWidth: CGFloat) -> CGFloat { 10 + lineWidth * 2.5 }
    static func headHalfWidth(lineWidth: CGFloat) -> CGFloat { headLength(lineWidth: lineWidth) * 0.45 }

    /// 返回 (杆的终点, 三角形三点)。杆缩短到三角形底边，避免线头穿出。
    static func build(from a: CGPoint, to b: CGPoint, lineWidth: CGFloat) -> (shaftEnd: CGPoint, head: [CGPoint]) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let hl = min(headLength(lineWidth: lineWidth), len)
        let hw = headHalfWidth(lineWidth: lineWidth)
        let base = CGPoint(x: b.x - ux * hl, y: b.y - uy * hl)
        let left = CGPoint(x: base.x - uy * hw, y: base.y + ux * hw)
        let right = CGPoint(x: base.x + uy * hw, y: base.y - ux * hw)
        return (base, [b, left, right])
    }

    /// Shift：把终点吸附到 45° 的整数倍方向，保持长度。
    static func snapped(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }
}

extension CGRect {
    /// Shift 拖矩形/椭圆：以锚点为固定角，取较大边长成正方形。
    static func square(anchor: CGPoint, drag p: CGPoint) -> CGRect {
        let side = max(abs(p.x - anchor.x), abs(p.y - anchor.y))
        let x = p.x >= anchor.x ? anchor.x : anchor.x - side
        let y = p.y >= anchor.y ? anchor.y : anchor.y - side
        return CGRect(x: x, y: y, width: side, height: side)
    }
}
