import CoreGraphics

/// 矩形的 8 个把手。
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// (x, y)：-1 贴左/上，0 居中，1 贴右/下。把手的几何全由它推导。
    var axes: (x: Int, y: Int) {
        switch self {
        case .topLeft: return (-1, -1)
        case .top: return (0, -1)
        case .topRight: return (1, -1)
        case .right: return (1, 0)
        case .bottomRight: return (1, 1)
        case .bottom: return (0, 1)
        case .bottomLeft: return (-1, 1)
        case .left: return (-1, 0)
        }
    }

    /// 拖拽时每帧都要查（翻转后要换光标），所以直接 switch。
    /// 走 allCases.first 的话每次都要新分配一个 8 元素数组
    init?(axes a: (x: Int, y: Int)) {
        switch (a.x, a.y) {
        case (-1, -1): self = .topLeft
        case (0, -1): self = .top
        case (1, -1): self = .topRight
        case (1, 0): self = .right
        case (1, 1): self = .bottomRight
        case (0, 1): self = .bottom
        case (-1, 1): self = .bottomLeft
        case (-1, 0): self = .left
        default: return nil
        }
    }
}

/// 矩形把手的布局、命中与拉伸。选区和标注共用同一套。
///
/// 单独拆出来是因为两者的尺度差了一个数量级：选区通常几百点，标注常常只有几十点。
/// 固定大小的命中区在小矩形上会互相盖住——点右下角却判成右边中点，结果只能改宽不能改高——
/// 所以命中区按矩形尺寸收缩，并且取最近的那个而不是列表里排第一个的。
enum HandleLayout {
    /// 把手画出来的直径（点）
    static let size: CGFloat = 8
    /// 命中半径上限。矩形小的时候按短边收缩，见 hitRadius
    static let maxRadius: CGFloat = 10
    /// 短于这个长度的边不给中点把手：它的命中区会被两端的角把手吃光，画出来也点不到。
    /// 推导：中点要和两个角各隔开一个命中直径才分得清 → 边长 ≥ 4 × maxRadius
    static let edgeHandleMinSide: CGFloat = 40

    static func center(_ h: Handle, of r: CGRect) -> CGPoint {
        let a = h.axes
        return CGPoint(x: a.x < 0 ? r.minX : (a.x > 0 ? r.maxX : r.midX),
                       y: a.y < 0 ? r.minY : (a.y > 0 ? r.maxY : r.midY))
    }

    /// 拉伸时固定不动的那个点。角把手取正对角；边中点把手的"无关维度"取 minX/minY，
    /// 由 resized 把活动点钉到 maxX/maxY 来补齐，于是那一维原样保留。
    static func opposite(_ h: Handle, in r: CGRect) -> CGPoint {
        let a = h.axes
        return CGPoint(x: a.x < 0 ? r.maxX : r.minX, y: a.y < 0 ? r.maxY : r.minY)
    }

    /// 这个矩形上实际可用的把手。短边不足 edgeHandleMinSide 就丢掉那一维的中点把手。
    static func handles(of r: CGRect) -> [Handle] {
        var hs: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if r.width >= edgeHandleMinSide { hs += [.top, .bottom] }
        if r.height >= edgeHandleMinSide { hs += [.left, .right] }
        return hs
    }

    /// 命中半径。矩形小的时候收缩到短边的三分之一，给"抓住中间拖动整体"留出空档，
    /// 否则把手会把内部铺满，小矩形就永远只能拉伸、不能拖动。
    static func hitRadius(of r: CGRect) -> CGFloat { hitRadius(span: min(r.width, r.height)) }
    static func hitRadius(span: CGFloat) -> CGFloat { max(3, min(maxRadius, span / 3)) }

    static func rects(of r: CGRect) -> [(Handle, CGRect)] {
        handles(of: r).map { h in
            let c = center(h, of: r)
            return (h, CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size))
        }
    }

    /// 命中区是圆的——把手画出来就是圆的。
    static func handle(at p: CGPoint, of r: CGRect) -> Handle? {
        nearest(at: p, among: handles(of: r).map { ($0, center($0, of: r)) }, radius: hitRadius(of: r))
    }

    /// 半径内离 p 最近的那个候选。平手时保留先出现的。
    static func nearest<H>(at p: CGPoint, among candidates: [(H, CGPoint)], radius: CGFloat) -> H? {
        var best: (handle: H, distance: CGFloat)?
        for (h, c) in candidates {
            let d = hypot(p.x - c.x, p.y - c.y)
            guard d <= radius else { continue }
            if let b = best, b.distance <= d { continue }
            best = (h, d)
        }
        return best?.handle
    }

    /// 把手拖到 p 之后的新矩形。固定点 o 那一侧不动，越过它矩形会自然翻转。
    ///
    /// r 传按下那一刻的矩形，全程以它为基准，不累积误差。
    /// minSide 是拉伸的下限：标注不该因为手一抖被拖成零尺寸而无声消失；
    /// 选区传 0，保持"拖到零就销毁"的老语义。
    static func resized(_ r: CGRect, handle h: Handle, to p: CGPoint, opposite o: CGPoint, minSide m: CGFloat = 0) -> CGRect {
        var q = p
        // 边中点把手不控制的那一维钉到 maxX/maxY，由下面的 normalized 还原成原值
        if h.axes.x == 0 { q.x = r.maxX }
        if h.axes.y == 0 { q.y = r.maxY }
        // 离固定点太近就沿原方向推开；正好重合时按把手自己的朝向挑一边
        func push(_ v: CGFloat, from anchor: CGFloat, axis: Int) -> CGFloat {
            guard abs(v - anchor) < m else { return v }
            return anchor + (v < anchor || (v == anchor && axis < 0) ? -m : m)
        }
        // 只钳把手自己控制的那个维度，别把 .top 拉成改宽度
        if h.axes.x != 0 { q.x = push(q.x, from: o.x, axis: h.axes.x) }
        if h.axes.y != 0 { q.y = push(q.y, from: o.y, axis: h.axes.y) }
        return Self.normalized(o, q)
    }

    /// 两点确定的矩形，允许宽高为 0 以便实时显示尺寸。越过对边自然翻转。
    static func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 拖过对边之后，手里的把手其实已经变成它的镜像。光标要跟着翻，否则方向是反的。
    static func live(_ h: Handle, in r: CGRect, opposite o: CGPoint) -> Handle {
        let a = h.axes
        // 固定点贴在左边 → 活动边在右，反之亦然
        let x = a.x == 0 ? 0 : (o.x <= r.minX ? 1 : -1)
        let y = a.y == 0 ? 0 : (o.y <= r.minY ? 1 : -1)
        return Handle(axes: (x, y)) ?? h
    }
}
