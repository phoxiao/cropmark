import AppKit

/// 截图覆盖层右上角的「截图历史」入口：和工具栏同款的浅色圆角底，显示图标和文字。
final class HistoryButton: NSView {
    static var size: CGSize {
        let title = L10n.t("截图历史") as NSString
        let width = title.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return CGSize(width: ceil(width) + 48, height: 36)
    }
    static let inset: CGFloat = 16

    /// 右上角，顶边让出菜单栏
    static func frame(in bounds: CGRect, topInset: CGFloat) -> CGRect {
        CGRect(x: bounds.maxX - inset - size.width, y: bounds.minY + max(topInset, 0) + inset,
               width: size.width, height: size.height)
    }

    private static let entranceKey = "historyButtonEntrance"
    private let action: () -> Void
    private let highlight = HighlightButton()

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
        let button = NSButton(title: L10n.t("截图历史"), target: self, action: #selector(openHistory))
        configure(button, tint: NSColor(white: 0.18, alpha: 1))
        button.toolTip = tooltip
        configure(highlight, tint: .white)
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.40, blue: 0.81, alpha: 1).cgColor
        highlight.layer?.cornerRadius = 8
        highlight.layer?.opacity = 0
        highlight.setAccessibilityElement(false)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, tint: NSColor) {
        button.title = L10n.t("截图历史")
        button.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.isBordered = false
        button.contentTintColor = tint
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        addSubview(button)
    }

    func animateEntrance(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        stopEntrance()
        let entranceDuration = 0.145
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.18 : entranceDuration
        layer?.add(fade, forKey: Self.entranceKey)
        guard !reduceMotion else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.88
        scale.toValue = 1
        scale.duration = entranceDuration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(scale, forKey: "historyButtonScale")

        // 蓝底和白色前景一起淡出，露出正常按钮，实际点击始终由正常按钮处理。
        let fadeStart = entranceDuration + 0.45
        let blue = CAKeyframeAnimation(keyPath: "opacity")
        blue.values = [1, 1, 0]
        blue.duration = fadeStart + 0.45
        blue.keyTimes = [0, NSNumber(value: fadeStart / blue.duration), 1]
        highlight.layer?.add(blue, forKey: Self.entranceKey)
    }

    func stopEntrance() {
        layer?.removeAnimation(forKey: Self.entranceKey)
        layer?.removeAnimation(forKey: "historyButtonScale")
        highlight.layer?.removeAnimation(forKey: Self.entranceKey)
    }

    private final class HighlightButton: NSButton {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @objc private func openHistory() { action() }

    /// 测试里直接点
    func performClick() { action() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) { /* 吞掉，不让覆盖层把它当成框选的起点 */ }
    override func rightMouseDown(with event: NSEvent) {}
}
