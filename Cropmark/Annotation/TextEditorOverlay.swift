import AppKit

/// 文字工具的就地输入框。Enter 或点击外部提交，Esc 放弃。
final class TextEditorOverlay: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// 提交时使用的样式；编辑中改颜色/粗细会同步到这里
    private(set) var annotationStyle = Style(color: Palette.colors[0], thickness: .medium)
    /// 折行宽度（点），从落点到选区右边界
    private(set) var maxWidth: CGFloat = 0

    static func make(at origin: CGPoint, style: Style, maxWidth: CGFloat) -> TextEditorOverlay {
        let width = max(maxWidth, 40)
        let tv = TextEditorOverlay(frame: NSRect(origin: origin, size: CGSize(width: width, height: style.thickness.fontSize * 1.5)))
        tv.maxWidth = width
        tv.isRichText = false
        tv.drawsBackground = false
        tv.apply(style: style)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.wantsLayer = true
        tv.layer?.borderColor = NSColor(white: 0.5, alpha: 0.8).cgColor
        tv.layer?.borderWidth = 1
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        return tv
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36 where !event.modifierFlags.contains(.shift): commit()
        default: super.keyDown(with: event)
        }
    }

    func apply(style: Style) {
        annotationStyle = style
        font = NSFont.systemFont(ofSize: style.thickness.fontSize, weight: .medium)
        textColor = style.color
        insertionPointColor = style.color
    }

    func commit() {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { onCancel?() } else { onCommit?(s) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}
