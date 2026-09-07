import CoreGraphics

/// 选区的 8 个把手。
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// 选区状态机。坐标系：所在屏幕的"视图坐标"，原点在屏幕左上角、y 向下、单位点。
/// 不碰 AppKit，纯逻辑，方便单元测试。
struct SelectionModel {
    enum Phase: Equatable {
        case idle
        case dragging(anchor: CGPoint)
        case selected
        case resizing(Handle, opposite: CGPoint)
        case moving(grabOffset: CGPoint)
    }

    static let handleSize: CGFloat = 8
    static let handleHitTolerance: CGFloat = 6
    /// 拖动距离小于该值视为"单击"，用于点选悬停窗口
    static let clickThreshold: CGFloat = 3

    let bounds: CGRect
    /// 屏幕缩放倍数。所有落点吸附到 1/scale 的网格上，这样选区边缘正好落在像素边界，
    /// 屏幕上显示的尺寸和导出图的像素尺寸才会一致。
    let scale: CGFloat
    private(set) var phase: Phase = .idle
    /// 已确定或正在拖出的选区
    private(set) var rect: CGRect?
    /// 光标悬停识别出的候选窗口
    var hoverRect: CGRect?

    init(bounds: CGRect, scale: CGFloat = 1) {
        self.bounds = bounds
        self.scale = max(scale, 1)
    }

    var isSelected: Bool { phase == .selected }
    var hasSelection: Bool { rect != nil }

    // MARK: 事件

    mutating func mouseDown(at p: CGPoint) {
        if phase == .selected, let r = rect {
            if let h = Self.handle(at: p, of: r) {
                phase = .resizing(h, opposite: Self.oppositeCorner(of: h, in: r))
                return
            }
            if r.contains(p) {
                phase = .moving(grabOffset: CGPoint(x: p.x - r.minX, y: p.y - r.minY))
                return
            }
        }
        rect = nil
        phase = .dragging(anchor: clamp(p))
    }

    mutating func mouseDragged(to p: CGPoint) {
        let p = clamp(p)
        switch phase {
        case .dragging(let anchor):
            rect = Self.normalized(anchor, p)
        case .resizing(let h, let opposite):
            guard let r = rect else { return }
            var q = p
            switch h {
            case .top, .bottom: q.x = r.maxX      // 只改高度
            case .left, .right: q.y = r.maxY      // 只改宽度
            default: break
            }
            rect = Self.normalized(opposite, q)
        case .moving(let offset):
            guard let r = rect else { return }
            var origin = CGPoint(x: p.x - offset.x, y: p.y - offset.y)
            origin.x = snap(min(max(origin.x, bounds.minX), bounds.maxX - r.width))
            origin.y = snap(min(max(origin.y, bounds.minY), bounds.maxY - r.height))
            rect = CGRect(origin: origin, size: r.size)
        case .idle, .selected:
            break
        }
    }

    mutating func mouseUp(at p: CGPoint) {
        switch phase {
        case .dragging(let anchor):
            let moved = hypot(p.x - anchor.x, p.y - anchor.y)
            if moved < Self.clickThreshold {
                // 单击：采用悬停窗口，没有就整屏
                rect = hoverRect.map(snapped) ?? bounds
            } else {
                rect = Self.normalized(anchor, clamp(p))
            }
            hoverRect = nil
            phase = .selected
        case .resizing, .moving:
            if let r = rect, r.width < 1 || r.height < 1 { rect = nil; phase = .idle }
            else { phase = .selected }
        case .idle, .selected:
            break
        }
    }

    mutating func clearSelection() {
        rect = nil
        phase = .idle
    }

    // MARK: 几何

    /// 两点确定的矩形，允许宽高为 0 以便实时显示尺寸
    static func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 限制在屏幕内并吸附到像素网格
    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: snap(min(max(p.x, bounds.minX), bounds.maxX)), y: snap(min(max(p.y, bounds.minY), bounds.maxY)))
    }

    func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    func snapped(_ r: CGRect) -> CGRect {
        let x0 = snap(r.minX), y0 = snap(r.minY), x1 = snap(r.maxX), y1 = snap(r.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func handleCenter(_ h: Handle, of r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    static func handleRects(of r: CGRect) -> [(Handle, CGRect)] {
        Handle.allCases.map { h in
            let c = handleCenter(h, of: r)
            return (h, CGRect(x: c.x - handleSize / 2, y: c.y - handleSize / 2, width: handleSize, height: handleSize))
        }
    }

    static func handle(at p: CGPoint, of r: CGRect) -> Handle? {
        for (h, hr) in handleRects(of: r) where hr.insetBy(dx: -handleHitTolerance, dy: -handleHitTolerance).contains(p) {
            return h
        }
        return nil
    }

    /// 拉伸时固定不动的那个点。边中点的把手把另一维固定在原值，由 anchoredDrag 处理。
    static func oppositeCorner(of h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.maxX, y: r.maxY)
        case .top: return CGPoint(x: r.minX, y: r.maxY)
        case .topRight: return CGPoint(x: r.minX, y: r.maxY)
        case .right: return CGPoint(x: r.minX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.minX, y: r.minY)
        case .bottom: return CGPoint(x: r.minX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.maxX, y: r.minY)
        case .left: return CGPoint(x: r.maxX, y: r.minY)
        }
    }
}
