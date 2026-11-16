import CoreGraphics

/// 标注上的把手。矩形和椭圆复用选区那 8 个；箭头是两个端点；画笔、马赛克、文字没有把手，只能整体拖。
enum AnnotationHandle: Equatable {
    case box(Handle)
    case start, end
}

/// 标注的命中判定与拖拽几何。
///
/// 文字要靠 TextKit 才能算出折行后的尺寸，所以把测量注入进来：
/// 几何逻辑本身不碰 AppKit，测试里换个 stub 就能把行为钉死。
struct AnnotationGeometry {
    /// (内容, 样式, 折行宽度) → 折行后的紧凑尺寸
    typealias TextMeasure = (String, Style, CGFloat) -> CGSize

    let measureText: TextMeasure

    /// 命中容差：描边半宽 + 5 点手指余量。细线(2) 得 6，中(4) 得 7，粗(6) 得 8。
    static func tolerance(_ lineWidth: CGFloat) -> CGFloat { lineWidth / 2 + 5 }
    /// 拉伸的最小边长：不小于线宽，免得粗线把自己缩成一个疙瘩。和新建时的 2×2 下限对得上。
    static func minSide(_ s: Style) -> CGFloat { max(2 * s.viewScale, s.lineWidth) }
    /// 箭头的最小长度，与新建时的下限一致
    static let minArrowLength: CGFloat = 3

    // MARK: 外接矩形

    /// 标注实际画出来占据的矩形。选中框和拖动钳制都用它。
    func bounds(of a: Annotation) -> CGRect {
        let lw = a.style.lineWidth
        switch a.shape {
        case .rect(let r), .ellipse(let r):
            return r
        case .arrow(let f, let t):
            // 头部三角会伸到线段两侧之外，要一起算进去
            let g = ArrowGeometry.build(from: f, to: t, lineWidth: a.style.thickness.lineWidth, scale: a.style.viewScale)
            return Self.box(of: [f, t] + g.head).insetBy(dx: -lw / 2, dy: -lw / 2)
        case .pen(let pts):
            return Self.box(of: pts).insetBy(dx: -lw / 2, dy: -lw / 2)
        case .mosaic(let pts):
            let hw = a.style.mosaicBrush / 2
            return Self.box(of: pts).insetBy(dx: -hw, dy: -hw)
        case .text(let s, let origin, let maxWidth):
            return CGRect(origin: origin, size: measureText(s, a.style, maxWidth))
        }
    }

    static func box(of pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        return pts.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    // MARK: 命中

    /// 这一点是否落在标注上。按形状精确判定，不用外接矩形——
    /// 否则一个大红框会把画在它内部的所有标注的点击全吃掉。
    func hits(_ a: Annotation, at p: CGPoint) -> Bool {
        let lw = a.style.lineWidth
        let t = Self.tolerance(lw)
        switch a.shape {
        case .rect(let r):
            // 整块算命中，点哪选哪。"从框内起笔画新的"靠单击/拖动区分，不靠这里挡
            return r.insetBy(dx: -t, dy: -t).contains(p)
        case .ellipse(let r):
            return Self.inside(ellipse: r.insetBy(dx: -t, dy: -t), p)
        case .arrow(let f, let to):
            if Self.distance(p, segment: f, to) <= t { return true }
            // 头部的两个"翅膀"比杆宽，只测线段会漏掉
            return Self.contains(triangle: ArrowGeometry.build(from: f, to: to, lineWidth: lw).head, p)
        case .pen(let pts):
            return Self.distance(p, polyline: pts) <= t
        case .mosaic(let pts):
            // 涂抹区域就是"到折线距离 ≤ 半个笔宽"，和渲染时的圆头描边严格一致。
            // 笔宽本来就有 14~32 点，不用再加余量，否则会吃掉旁边的标注
            return Self.distance(p, polyline: pts) <= a.style.mosaicBrush / 2
        case .text:
            // 文字是实心的，整块算命中，再外扩一点方便抓
            return bounds(of: a).insetBy(dx: -4, dy: -3).contains(p)
        }
    }

    /// 命中判定的第一轮：只认"确凿属于这条标注的墨迹"。
    /// 矩形和椭圆的肚子是空的，第一轮只认边线，好让"点在谁的线上"先决出胜负。
    /// 箭头、画笔、马赛克本来就只有描边，两轮同结果；
    /// 文字虽然也是整块，但那整块就是它的墨迹所在，不是兜底——所以它也该赢第一轮。
    func hitsStroke(_ a: Annotation, at p: CGPoint) -> Bool {
        let t = Self.tolerance(a.style.lineWidth)
        switch a.shape {
        case .rect(let r): return Self.hitsBorder(r, at: p, tolerance: t)
        case .ellipse(let r): return Self.hitsEllipse(r, at: p, tolerance: t)
        case .arrow, .pen, .mosaic, .text: return hits(a, at: p)
        }
    }

    /// 后画的压在上面（和渲染顺序一致），但"点在谁的线上"永远赢过"点在谁的肚子里"——
    /// 否则最后框的那个大圈，会把它内部先画的箭头、文字全吃掉，
    /// 而"先标注细节、最后框个总的圈起来"恰恰是很常见的顺序。
    func topmost(at p: CGPoint, in items: [Annotation]) -> Annotation? {
        let item = items.last { hitsStroke($0, at: p) } ?? items.last { hits($0, at: p) }
        return item?.isBakedMosaic == true ? nil : item
    }

    /// 描边带：外扩 t 命中、内缩 t 不命中。
    /// 内缩之后已经没有内圈了（小图形）就整块算命中，否则几十点的小框根本点不着。
    private static func hitsBand(_ r: CGRect, tolerance t: CGFloat, contains: (CGRect) -> Bool) -> Bool {
        guard contains(r.insetBy(dx: -t, dy: -t)) else { return false }
        let inner = r.insetBy(dx: t, dy: t)
        return !(inner.width > 0 && inner.height > 0 && contains(inner))
    }

    static func hitsBorder(_ r: CGRect, at p: CGPoint, tolerance t: CGFloat) -> Bool {
        hitsBand(r, tolerance: t) { $0.contains(p) }
    }

    /// 椭圆的描边带同样是外扩/内缩各 t 的两条同心椭圆夹层。
    /// 不用"从中心发射线求交点"那种近似——400×40 的扁椭圆在中段会把距离高估好几倍，根本点不中。
    static func hitsEllipse(_ r: CGRect, at p: CGPoint, tolerance t: CGFloat) -> Bool {
        hitsBand(r, tolerance: t) { inside(ellipse: $0, p) }
    }

    static func inside(ellipse r: CGRect, _ p: CGPoint) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let u = (p.x - r.midX) / (r.width / 2), v = (p.y - r.midY) / (r.height / 2)
        return u * u + v * v <= 1
    }

    /// 点到线段的距离。线段退化成一点时就是点距，单点笔迹也能点中。
    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 到折线各段的最小距离。注意是逐段算，不是首尾连线——画个 L 形，拐角内侧不该算命中。
    static func distance(_ p: CGPoint, polyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        return zip(pts, pts.dropFirst()).reduce(CGFloat.infinity) { min($0, distance(p, segment: $1.0, $1.1)) }
    }

    /// 点在三角形内。三个叉积同号即可，顺逆时针都适用。
    static func contains(triangle t: [CGPoint], _ p: CGPoint) -> Bool {
        guard t.count == 3 else { return false }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d0 = cross(t[0], t[1], p), d1 = cross(t[1], t[2], p), d2 = cross(t[2], t[0], p)
        return !((d0 < 0 || d1 < 0 || d2 < 0) && (d0 > 0 || d1 > 0 || d2 > 0))
    }

    // MARK: 把手

    func handles(of a: Annotation) -> [(AnnotationHandle, CGPoint)] {
        switch a.shape {
        case .rect(let r), .ellipse(let r):
            return HandleLayout.handles(of: r).map { (.box($0), HandleLayout.center($0, of: r)) }
        case .arrow(let f, let t):
            return [(.start, f), (.end, t)]
        case .pen, .mosaic, .text:
            return []
        }
    }

    /// 把手的命中半径，跟着标注尺寸收缩，小标注上才不会互相盖住。
    func handleRadius(of a: Annotation) -> CGFloat {
        switch a.shape {
        case .rect(let r), .ellipse(let r):
            return HandleLayout.hitRadius(of: r)
        case .arrow(let f, let t):
            // 短箭头的两个端点会挨得很近，按长度收缩，保证"点哪头拉哪头"
            return HandleLayout.hitRadius(span: hypot(t.x - f.x, t.y - f.y))
        case .pen, .mosaic, .text:
            return 0
        }
    }

    func handle(at p: CGPoint, of a: Annotation) -> AnnotationHandle? {
        HandleLayout.nearest(at: p, among: handles(of: a), radius: handleRadius(of: a))
    }

    // MARK: 拖拽

    /// 整体平移。id 和样式原样保留，只动几何。
    static func moved(_ a: Annotation, by d: CGVector) -> Annotation {
        var out = a
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        switch a.shape {
        case .rect(let r): out.shape = .rect(r.offsetBy(dx: d.dx, dy: d.dy))
        case .ellipse(let r): out.shape = .ellipse(r.offsetBy(dx: d.dx, dy: d.dy))
        case .arrow(let f, let t): out.shape = .arrow(from: shift(f), to: shift(t))
        case .pen(let pts): out.shape = .pen(pts.map(shift))
        case .mosaic(let pts): out.shape = .mosaic(pts.map(shift))
        case .text(let s, let o, let w): out.shape = .text(s, origin: shift(o), maxWidth: w)
        }
        return out
    }

    /// 拖把手之后的标注。origin 传按下那一刻的那条，全程以它为基准重算，不累积误差。
    /// 拖过头会翻转；拖到零尺寸会被钳到最小值而不是消失——手一抖就无声删掉一条标注太伤。
    static func resized(_ a: Annotation, handle h: AnnotationHandle, to p: CGPoint, shift: Bool) -> Annotation {
        var out = a
        let m = minSide(a.style)
        switch (a.shape, h) {
        case (.rect(let r), .box(let bh)):
            out.shape = .rect(resizedBox(r, bh, to: p, shift: shift, minSide: m))
        case (.ellipse(let r), .box(let bh)):
            out.shape = .ellipse(resizedBox(r, bh, to: p, shift: shift, minSide: m))
        case (.arrow(let f, let t), .start):
            out.shape = .arrow(from: movedEnd(p, opposite: t, shift: shift, fallback: f, scale: a.style.viewScale), to: t)
        case (.arrow(let f, let t), .end):
            out.shape = .arrow(from: f, to: movedEnd(p, opposite: f, shift: shift, fallback: t, scale: a.style.viewScale))
        default:
            break
        }
        return out
    }

    private static func resizedBox(_ r: CGRect, _ h: Handle, to p: CGPoint, shift: Bool, minSide m: CGFloat) -> CGRect {
        let o = HandleLayout.opposite(h, in: r)
        // Shift 拉角成正方形，和新建时一致。边中点没有"正方形"的说法，照常走
        guard shift, h.axes.x != 0, h.axes.y != 0 else {
            return HandleLayout.resized(r, handle: h, to: p, opposite: o, minSide: m)
        }
        var q = p
        if max(abs(p.x - o.x), abs(p.y - o.y)) < m {
            q = CGPoint(x: o.x + (p.x < o.x ? -m : m), y: o.y + (p.y < o.y ? -m : m))
        }
        return CGRect.square(anchor: o, drag: q)
    }

    /// 拉箭头的一端：Shift 吸附以另一端为基准，太短就沿当前方向推开，不让它退化成一个点。
    private static func movedEnd(_ p: CGPoint, opposite o: CGPoint, shift: Bool, fallback: CGPoint, scale: CGFloat) -> CGPoint {
        let q = shift ? ArrowGeometry.snapped(from: o, to: p) : p
        let len = hypot(q.x - o.x, q.y - o.y)
        let minimum = minArrowLength * scale
        guard len < minimum else { return q }
        let dir = len > 0 ? CGPoint(x: (q.x - o.x) / len, y: (q.y - o.y) / len) : unit(from: o, to: fallback)
        return CGPoint(x: o.x + dir.x * minimum, y: o.y + dir.y * minimum)
    }

    private static func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 0 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d)
    }

    /// 把位移限制住，让外接矩形 b 不出 limit。
    /// b 比 limit 还大时（选区后来被缩小过），允许在"仍然盖住 limit"的范围里滑动，而不是被强行拉回。
    static func clampedOffset(_ d: CGVector, of b: CGRect, within limit: CGRect) -> CGVector {
        func axis(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            min(max(v, min(lo, hi)), max(lo, hi))
        }
        return CGVector(dx: axis(d.dx, limit.minX - b.minX, limit.maxX - b.maxX),
                        dy: axis(d.dy, limit.minY - b.minY, limit.maxY - b.maxY))
    }
}
