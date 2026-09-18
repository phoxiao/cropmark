import AppKit

enum ToolKind: CaseIterable {
    case rect, ellipse, arrow, pen, mosaic, text

    var title: String {
        switch self {
        case .rect: return L10n.t("矩形")
        case .ellipse: return L10n.t("椭圆")
        case .arrow: return L10n.t("箭头")
        case .pen: return L10n.t("画笔")
        case .mosaic: return L10n.t("马赛克")
        case .text: return L10n.t("文字")
        }
    }
    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .mosaic: return "square.grid.3x3.square"
        case .text: return "textformat"
        }
    }
}

enum Thickness: Int, CaseIterable {
    case thin, medium, thick
    var lineWidth: CGFloat { [2, 4, 6][rawValue] }
    var fontSize: CGFloat { [14, 18, 24][rawValue] }
    /// 马赛克块边长（点）
    var mosaicBlock: CGFloat { [6, 10, 16][rawValue] }
    /// 马赛克涂抹笔宽（点）
    var mosaicBrush: CGFloat { [14, 22, 32][rawValue] }
    var dotDiameter: CGFloat { [6, 9, 12][rawValue] }
    var title: String { L10n.t(["细", "中", "粗"][rawValue]) }
}

struct Style: Equatable {
    var color: NSColor
    var thickness: Thickness
}

enum Palette {
    /// 标注调色板：红、橙、蓝、绿、黑、白（常见截图工具的通用六色）
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.19, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.50, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.76, blue: 0.38, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    ]
    /// 强调色：选区边框、把手、完成按钮、选中的工具。与应用图标里的蓝同系。
    static let accent = NSColor(srgbRed: 0x4F / 255, green: 0x7D / 255, blue: 1.0, alpha: 1)
}

/// 一条标注。所有坐标为所在屏幕的视图坐标（原点左上、y 向下、单位点）。
/// id 让「选中某条、改它、撤销」有稳定的指代：数组下标会被撤销回滚打乱。
struct Annotation: Identifiable, Equatable {
    /// 只管几何和内容。颜色粗细统一提到 style，
    /// 这样「改选中那条的样式」是一行赋值，而不是按形状写六路 switch。
    enum Shape: Equatable {
        case rect(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
        case mosaic([CGPoint])
        /// maxWidth：折行宽度（点），与就地编辑框一致，导出才能所见即所得
        case text(String, origin: CGPoint, maxWidth: CGFloat)
    }

    let id = UUID()
    var shape: Shape
    /// 马赛克只用到 thickness，color 由渲染器忽略
    var style: Style

    /// 马赛克没有颜色可言，工具栏要把色板藏起来
    var isMosaic: Bool { if case .mosaic = shape { return true }; return false }
}

extension Annotation.Shape {
    /// 矩形和椭圆背后的那个 CGRect，其余形状没有
    var box: CGRect? {
        switch self {
        case .rect(let r), .ellipse(let r): return r
        default: return nil
        }
    }
}

/// 标注列表 + 撤销/重做。
/// 撤销栈存整份列表快照：数组是写时复制，没动过的点集不会真复制，
/// 比给「增/删/改几何/改样式」各写一遍逆操作可靠得多，量级本来也就十几条。
final class AnnotationStore {
    private(set) var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    /// 一次拖动开始时的快照。非 nil 表示正处在连续编辑里，中途每帧的改动都不单独入栈。
    private var dragBaseline: [Annotation]?
    private static let limit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func item(id: Annotation.ID) -> Annotation? { items.first { $0.id == id } }

    // MARK: 原子修改（各占一条撤销）

    func append(_ a: Annotation) { mutate { $0.append(a) } }
    func remove(id: Annotation.ID) { mutate { $0.removeAll { $0.id == id } } }

    /// 就地改一条。id 已经不在了（比如刚被撤销掉）就什么都不做。
    func update(id: Annotation.ID, _ body: (inout Annotation) -> Void) {
        mutate { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            body(&list[i])
        }
    }
    func replace(id: Annotation.ID, with a: Annotation) { update(id: id) { $0 = a } }

    // MARK: 连续编辑（一整次拖动只占一条撤销）

    /// 重入安全：重复调用不会覆盖基线
    func beginDrag() { if dragBaseline == nil { dragBaseline = items } }
    func endDrag() {
        guard let base = dragBaseline else { return }
        dragBaseline = nil
        guard base != items else { return }   // 按下没动就松开，不该占一条撤销
        push(base)
    }
    // MARK: 撤销

    @discardableResult
    func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(items)
        items = prev
        return true
    }
    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(items)
        items = next
        return true
    }

    /// 重新框选：连撤销栈一起清。旧选区里的标注已经没有意义，
    /// 也不该被 ⌘Z 复活到一个不存在的选区里。
    func removeAll() {
        items.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        dragBaseline = nil
    }

    private func mutate(_ body: (inout [Annotation]) -> Void) {
        // 拖动中的改动并进本次拖动，等 endDrag 一起记。先判它再取快照：
        // 否则拖拽每帧都要白复制一次数组、白比一次全表
        guard dragBaseline == nil else { body(&items); return }
        let before = items
        body(&items)
        guard items != before else { return }
        push(before)
    }
    private func push(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > Self.limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }
}
