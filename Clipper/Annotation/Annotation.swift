import AppKit

enum ToolKind: CaseIterable {
    case rect, ellipse, arrow, pen, mosaic, text

    var title: String {
        switch self {
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
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
    var title: String { ["细", "中", "粗"][rawValue] }
}

struct Style: Equatable {
    var color: NSColor
    var thickness: Thickness
}

enum Palette {
    /// 微信截图的 6 色：红、橙、蓝、绿、黑、白
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.19, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.50, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.76, blue: 0.38, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    ]
    static let accent = NSColor(srgbRed: 0.03, green: 0.76, blue: 0.38, alpha: 1)
}

/// 一条标注。所有坐标为所在屏幕的视图坐标（原点左上、y 向下、单位点）。
enum Annotation {
    case rect(CGRect, Style)
    case ellipse(CGRect, Style)
    case arrow(from: CGPoint, to: CGPoint, Style)
    case pen([CGPoint], Style)
    case mosaic([CGPoint], Thickness)
    case text(String, origin: CGPoint, Style)
}

/// 标注列表 + 撤销。
final class AnnotationStore {
    private(set) var items: [Annotation] = []
    var canUndo: Bool { !items.isEmpty }
    func append(_ a: Annotation) { items.append(a) }
    @discardableResult
    func undo() -> Annotation? { items.popLast() }
    func removeAll() { items.removeAll() }
}
