import AppKit

/// 文字工具的就地输入框。Enter 或点击外部提交，Esc 放弃。
final class TextEditorOverlay: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// 提交时使用的样式；编辑中改颜色/粗细会同步到这里
    private(set) var annotationStyle = Style(color: Palette.colors[0], thickness: .medium)
    /// 折行宽度（点），从落点到选区右边界
    private(set) var maxWidth: CGFloat = 0

    /// text 非空即为"重新编辑一条已提交的文字"：预填内容、撑开高度、光标落到末尾。
    static func make(at origin: CGPoint, style: Style, maxWidth: CGFloat, text: String = "") -> TextEditorOverlay {
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
        if !text.isEmpty {
            tv.string = text
            tv.apply(style: style)   // 设完内容再刷一遍，字体颜色才落到已有文字上
            // 用和渲染同一份测量撑开高度，否则多行文字一进来就被框裁掉
            let h = AnnotationRenderer.textRect(AnnotationRenderer.attributedText(text, style: style),
                                                origin: origin, maxWidth: width).height
            tv.frame.size.height = max(h, style.thickness.fontSize * 1.5)
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
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

    /// 空内容不再偷偷走 onCancel：新建时"空"是不留东西，重编辑时"空"是删掉这一条，
    /// 而 Esc 无论哪种都是放弃改动。三件事语义不同，交给调用方判断。
    func commit() { onCommit?(string.trimmingCharacters(in: .whitespacesAndNewlines)) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}
