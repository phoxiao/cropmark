import AppKit

/// 截图覆盖层右上角的「截图历史」入口：和工具栏同款的浅色圆角底，里面一个按钮。
final class HistoryButton: NSView {
    static let size = CGSize(width: 36, height: 36)
    static let inset: CGFloat = 16

    /// 右上角，顶边让出菜单栏
    static func frame(in bounds: CGRect, topInset: CGFloat) -> CGRect {
        CGRect(x: bounds.maxX - inset - size.width, y: bounds.minY + max(topInset, 0) + inset,
               width: size.width, height: size.height)
    }

    private let action: () -> Void

    override var isFlipped: Bool { true }

    init(tooltip: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.97).cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.masksToBounds = false
        let button = ToolButton(symbol: "clock.arrow.circlepath", tooltip: tooltip, action: action)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 测试里直接点
    func performClick() { action() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) { /* 吞掉，不让覆盖层把它当成框选的起点 */ }
    override func rightMouseDown(with event: NSEvent) {}
}
