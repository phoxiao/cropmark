import CoreGraphics

/// 标注的选中与拖拽。和 SelectionModel 同构：纯状态机 + 纯几何，
/// OverlayView 只管喂事件、把结果写回 store、画出来。
struct AnnotationEditor {
    enum Drag: Equatable {
        /// grab 是按下时的落点，origin 是按下时的那条标注。
        /// 全程以 origin 为基准重算而不是叠加增量——和绘制时从锚点重建是同一个思路，不累积误差。
        case moving(grab: CGPoint, origin: Annotation)
        case resizing(AnnotationHandle, origin: Annotation)
    }

    let geometry: AnnotationGeometry
    /// 标注不得越出的范围 = 当前选区。越出的部分渲染和导出都会被裁掉，等于凭空消失
    var limit: CGRect = .zero
    /// 屏幕倍率，落点吸附到 1/scale 网格
    private let scale: CGFloat

    private(set) var selected: Annotation.ID?
    private(set) var drag: Drag?

    init(geometry: AnnotationGeometry, scale: CGFloat = 1) {
        self.geometry = geometry
        self.scale = max(scale, 1)
    }

    var isDragging: Bool { drag != nil }

    mutating func select(_ id: Annotation.ID?) { selected = id }

    mutating func beginMoving(_ a: Annotation, grab p: CGPoint) {
        selected = a.id
        drag = .moving(grab: p, origin: a)
    }
    mutating func beginResizing(_ a: Annotation, handle h: AnnotationHandle) {
        selected = a.id
        drag = .resizing(h, origin: a)
    }
    mutating func endDrag() { drag = nil }

    /// 拖拽到 p 之后这条标注应该长什么样，由调用方写回 store。
    func dragged(to p: CGPoint, shift: Bool) -> Annotation? {
        switch drag {
        case .moving(let grab, let origin):
            // 手抖几个点不算拖动：标注整块可点之后框内是个实心大靶子，
            // 不挡的话"点一下选中"会顺手把它挪走，还占掉一条撤销
            guard hypot(p.x - grab.x, p.y - grab.y) >= SelectionModel.clickThreshold else { return origin }
            // 钳的是位移而不是鼠标点：抓着一条长笔迹的右端往左拖，
            // 钳鼠标点会把左端挤出选区，钳位移才是刚体平移，形状分毫不动
            let raw = CGVector(dx: snap(p.x - grab.x), dy: snap(p.y - grab.y))
            let d = AnnotationGeometry.clampedOffset(raw, of: geometry.bounds(of: origin), within: limit)
            return AnnotationGeometry.moved(origin, by: d)
        case .resizing(let h, let origin):
            // 拉把手钳的是鼠标点：固定点本来就在选区内，两点都在内矩形必在内
            return AnnotationGeometry.resized(origin, handle: h, to: clamp(p), shift: shift)
        case nil:
            return nil
        }
    }

    /// 拖拽中当前实际对应的把手：拉伸拖过对边后手里的把手已经变成镜像，光标要跟着翻。
    func liveHandle(of a: Annotation) -> AnnotationHandle? {
        guard case .resizing(let h, let origin) = drag else { return nil }
        guard case .box(let b) = h, let now = Self.box(of: a), let was = Self.box(of: origin) else { return h }
        return .box(HandleLayout.live(b, in: now, opposite: HandleLayout.opposite(b, in: was)))
    }

    /// 矩形/椭圆背后的那个 CGRect，其余形状没有
    private static func box(of a: Annotation) -> CGRect? {
        switch a.shape {
        case .rect(let r), .ellipse(let r): return r
        default: return nil
        }
    }

    func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: snap(min(max(p.x, limit.minX), limit.maxX)),
                y: snap(min(max(p.y, limit.minY), limit.maxY)))
    }
}
