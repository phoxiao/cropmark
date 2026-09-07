import AppKit

/// 一块屏幕上的截图交互层：冻结画面、遮罩、选区、标注、工具栏。
/// 视图坐标翻转（原点左上、y 向下），与像素图方向一致。
final class OverlayView: NSView {
    private let snapshot: ScreenSnapshot
    /// 会话可能先于窗口释放（晚到的鼠标事件），用 weak 防止悬垂
    private weak var session: CaptureSession?
    private var selection: SelectionModel
    private let store = AnnotationStore()
    private let toolbar = ToolbarPanel()

    private var tool: ToolKind?
    private var style = Style(color: Palette.colors[0], thickness: .medium)
    private var inProgress: Annotation?
    private var drawAnchor: CGPoint?
    private var textEditor: TextEditorOverlay?
    private var bystander = false
    private var pixelCache: [Thickness: CGImage] = [:]
    private lazy var renderer = AnnotationRenderer(screenSize: bounds.size) { [weak self] t in self?.pixelated(t) }

    private static let dimColor = NSColor(white: 0, alpha: 0.45)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(snapshot: ScreenSnapshot, session: CaptureSession) {
        self.snapshot = snapshot
        self.session = session
        let b = CGRect(origin: .zero, size: snapshot.frame.size)
        self.selection = SelectionModel(bounds: b)
        super.init(frame: b)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))

        toolbar.isHidden = true
        addSubview(toolbar)
        toolbar.onSelectTool = { [weak self] t in
            guard let self else { return }
            self.commitTextEditor()
            self.tool = t
            self.layoutToolbar()
            self.needsDisplay = true
        }
        toolbar.onStyleChange = { [weak self] s in self?.style = s }
        toolbar.onAction = { [weak self] a in
            guard let self else { return }
            switch a {
            case .undo: self.undo()
            case .save: self.finish(save: true)
            case .cancel: self.session?.cancel()
            case .done: self.finish(save: false)
            }
        }
        selection.hoverRect = b
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 测试钩子

    var currentSelection: CGRect? { selection.rect }
    var isToolbarVisible: Bool { !toolbar.isHidden }
    var annotationCount: Int { store.items.count }
    func selectToolForTesting(_ t: ToolKind?) { toolbar.selectTool(t) }

    // MARK: 旁观（其他屏幕已有选区）

    func becomeBystander() { bystander = true; selection.hoverRect = nil; needsDisplay = true }
    func leaveBystander() { bystander = false; needsDisplay = true }

    // MARK: 坐标换算

    private func screenPoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: snapshot.frame.minX + p.x, y: snapshot.frame.maxY - p.y)
    }
    private func viewRect(fromScreen r: CGRect) -> CGRect {
        CGRect(x: r.minX - snapshot.frame.minX, y: snapshot.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func updateHover(at p: CGPoint) {
        guard !bystander, !selection.hasSelection else { return }
        let sp = screenPoint(fromView: p)
        if let w = WindowLocator.topmostWindow(at: sp, in: session?.windowList ?? [], clampTo: snapshot.frame) {
            selection.hoverRect = viewRect(fromScreen: w)
        } else {
            selection.hoverRect = bounds
        }
        needsDisplay = true
    }

    // MARK: 鼠标

    override func mouseEntered(with event: NSEvent) {
        guard !bystander else { return }
        if session?.activeView == nil { window?.makeKey() }
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        if !selection.hasSelection { selection.hoverRect = nil; needsDisplay = true }
    }
    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard !bystander else { return }
        let p = convert(event.locationInWindow, from: nil)
        if textEditor != nil { commitTextEditor(); return }

        if let tool, selection.isSelected, let r = selection.rect, r.contains(p) {
            beginDrawing(tool, at: p, in: r)
            return
        }
        if event.clickCount == 2, selection.isSelected, let r = selection.rect, r.contains(p) {
            finish(save: false)
            return
        }
        let hadSelection = selection.hasSelection
        selection.mouseDown(at: p)
        if case .dragging = selection.phase {
            // 重新框选：丢弃旧标注
            store.removeAll()
            toolbar.canUndo = false
            toolbar.isHidden = true
            if !hadSelection { session?.selectionDidBegin(on: self) }
        } else {
            toolbar.isHidden = true
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !bystander else { return }
        let p = convert(event.locationInWindow, from: nil)
        if inProgress != nil || drawAnchor != nil {
            continueDrawing(to: p, shift: event.modifierFlags.contains(.shift))
        } else {
            selection.mouseDragged(to: p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !bystander else { return }
        let p = convert(event.locationInWindow, from: nil)
        if inProgress != nil || drawAnchor != nil {
            endDrawing(at: p, shift: event.modifierFlags.contains(.shift))
        } else {
            selection.mouseUp(at: p)
            if selection.isSelected { layoutToolbar(); toolbar.isHidden = false }
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if textEditor != nil { commitTextEditor(); return }
        if selection.hasSelection {
            selection.clearSelection()
            store.removeAll()
            toolbar.canUndo = false
            toolbar.deselectTool()
            tool = nil
            toolbar.isHidden = true
            session?.selectionDidClear()
            updateHover(at: convert(event.locationInWindow, from: nil))
            needsDisplay = true
        } else {
            session?.cancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: session?.cancel()                                    // Esc
        case 36, 76: if selection.isSelected { finish(save: false) } // Return / Enter
        default:
            if cmd, event.charactersIgnoringModifiers == "z" { undo() }
            else if cmd, event.charactersIgnoringModifiers == "s", selection.isSelected { finish(save: true) }
            else { super.keyDown(with: event) }
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: 绘制标注

    private func beginDrawing(_ tool: ToolKind, at p: CGPoint, in r: CGRect) {
        switch tool {
        case .rect, .ellipse, .arrow:
            drawAnchor = p
        case .pen:
            inProgress = .pen([p], style)
        case .mosaic:
            inProgress = .mosaic([p], style.thickness)
        case .text:
            let editor = TextEditorOverlay.make(at: p, style: style, maxWidth: r.maxX - p.x)
            editor.onCommit = { [weak self, weak editor] s in
                guard let self, let editor else { return }
                self.store.append(.text(s, origin: editor.frame.origin, self.style))
                self.toolbar.canUndo = true
                self.removeTextEditor()
            }
            editor.onCancel = { [weak self] in self?.removeTextEditor() }
            addSubview(editor)
            textEditor = editor
            window?.makeFirstResponder(editor)
        }
    }

    private func continueDrawing(to p: CGPoint, shift: Bool) {
        let q = clampToSelection(p)
        if let a = drawAnchor, let tool {
            switch tool {
            case .rect: inProgress = .rect(shift ? .square(anchor: a, drag: q) : SelectionModel.normalized(a, q), style)
            case .ellipse: inProgress = .ellipse(shift ? .square(anchor: a, drag: q) : SelectionModel.normalized(a, q), style)
            case .arrow: inProgress = .arrow(from: a, to: shift ? ArrowGeometry.snapped(from: a, to: q) : q, style)
            default: break
            }
        } else if case .pen(var pts, let s) = inProgress {
            pts.append(q); inProgress = .pen(pts, s)
        } else if case .mosaic(var pts, let t) = inProgress {
            pts.append(q); inProgress = .mosaic(pts, t)
        }
    }

    private func endDrawing(at p: CGPoint, shift: Bool) {
        continueDrawing(to: p, shift: shift)
        defer { inProgress = nil; drawAnchor = nil }
        guard let a = inProgress else { return }
        switch a {
        case .rect(let r, _), .ellipse(let r, _):
            guard r.width >= 2, r.height >= 2 else { return }
        case .arrow(let f, let t, _):
            guard hypot(t.x - f.x, t.y - f.y) >= 3 else { return }
        default: break
        }
        store.append(a)
        toolbar.canUndo = true
    }

    private func clampToSelection(_ p: CGPoint) -> CGPoint {
        guard let r = selection.rect else { return p }
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private func undo() {
        commitTextEditor()
        store.undo()
        toolbar.canUndo = store.canUndo
        needsDisplay = true
    }

    private func commitTextEditor() { textEditor?.commit() }
    private func removeTextEditor() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func pixelated(_ t: Thickness) -> CGImage? {
        if let c = pixelCache[t] { return c }
        let img = Mosaic.pixelate(snapshot.image, blockPixels: Int(t.mosaicBlock * snapshot.scale))
        pixelCache[t] = img
        return img
    }

    // MARK: 工具栏

    private func layoutToolbar() {
        guard let r = selection.rect else { return }
        let size = toolbar.preferredSize
        toolbar.frame = ToolbarPlacement.frame(selection: r, size: size, bounds: bounds)
        toolbar.layoutSubtreeIfNeeded()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: 完成

    private func finish(save: Bool) {
        commitTextEditor()
        guard let r = selection.rect, r.width >= 1, r.height >= 1 else { return }
        guard let img = ImageComposer.compose(snapshot: snapshot, selection: r, annotations: store.items, renderer: renderer) else {
            session?.cancel(); return
        }
        if save { session?.save(img) } else { session?.complete(with: img) }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        AnnotationRenderer.drawImage(snapshot.image, in: bounds, ctx: ctx)

        if let r = selection.rect, !r.isEmpty {
            ctx.saveGState()
            ctx.clip(to: r)
            renderer.draw(store.items, in: ctx)
            if let a = inProgress { renderer.draw(a, in: ctx) }
            ctx.restoreGState()
        }

        let hole: CGRect? = selection.rect ?? (bystander ? nil : selection.hoverRect)
        ctx.setFillColor(Self.dimColor.cgColor)
        if let hole, !hole.isEmpty {
            ctx.addRect(bounds)
            ctx.addRect(hole)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }

        guard let hole, !hole.isEmpty else { return }
        ctx.setStrokeColor(Palette.accent.cgColor)
        ctx.setLineWidth(selection.hasSelection ? 1.5 : 2)
        ctx.stroke(hole.insetBy(dx: -0.75, dy: -0.75))

        if selection.hasSelection, tool == nil {
            ctx.setFillColor(NSColor.white.cgColor)
            for (_, hr) in SelectionModel.handleRects(of: hole) {
                ctx.fillEllipse(in: hr)
                ctx.strokeEllipse(in: hr)
            }
        }

        if selection.hasSelection || selection.hoverRect != nil {
            drawSizeLabel(for: hole, in: ctx)
        }
    }

    private func drawSizeLabel(for r: CGRect, in ctx: CGContext) {
        let w = Int((r.width * snapshot.scale).rounded()), h = Int((r.height * snapshot.scale).rounded())
        let attr = NSAttributedString(string: "\(w) × \(h)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = attr.size()
        let pad: CGFloat = 6
        var origin = CGPoint(x: r.minX, y: r.minY - size.height - pad * 2 - 4)
        var bg = CGRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad)
        // 上方放不下，或者会被工具栏盖住，就挪到选区内部左上角
        if origin.y < 0 || (!toolbar.isHidden && toolbar.frame.intersects(bg)) {
            origin = CGPoint(x: r.minX + 4, y: r.minY + 4)
        }
        origin.x = min(max(origin.x, 0), bounds.maxX - size.width - pad * 2)
        bg = CGRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        attr.draw(at: CGPoint(x: bg.minX + pad, y: bg.minY + pad / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}
