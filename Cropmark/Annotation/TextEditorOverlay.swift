import AppKit

/// 文字工具的就地输入框。Enter 或点击外部提交，Esc 放弃。
final class TextEditorOverlay: NSTextView {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    static func make(at origin: CGPoint, style: Style, maxWidth: CGFloat) -> TextEditorOverlay {
        let tv = TextEditorOverlay(frame: NSRect(origin: origin, size: CGSize(width: max(maxWidth, 40), height: style.thickness.fontSize * 1.5)))
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: style.thickness.fontSize, weight: .medium)
        tv.textColor = style.color
        tv.insertionPointColor = style.color
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

    func commit() {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { onCancel?() } else { onCommit?(s) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}
