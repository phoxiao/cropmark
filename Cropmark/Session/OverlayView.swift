import AppKit

/// 一块屏幕上的截图交互层：冻结画面、遮罩、选区、标注、工具栏。
/// 视图坐标翻转（原点左上、y 向下），与像素图方向一致。
final class OverlayView: NSView {
    private let snapshot: ScreenSnapshot
    /// 会话可能先于窗口释放（晚到的鼠标事件），用 weak 防止悬垂
    private weak var session: CaptureSession?
    private var selection: SelectionModel
    /// 块级识别：每块屏幕一份，因为它要看这块屏幕自己的冻结截图
    private let hoverResolver: HoverResolver?
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
        self.selection = SelectionModel(bounds: b, scale: snapshot.scale)
        self.hoverResolver = session.elementDetection.resolver(for: snapshot)
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
            self.refreshCursor()
        }
        toolbar.onStyleChange = { [weak self] s in
            self?.style = s
            self?.textEditor?.apply(style: s)
        }
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
    var annotationsForTesting: [Annotation] { store.items }
    var isBystander: Bool { bystander }
    var hoverRectForTesting: CGRect? { selection.hoverRect }
    func selectToolForTesting(_ t: ToolKind?) { toolbar.selectTool(t) }
    func cursorForTesting(at p: CGPoint) -> NSCursor { cursor(at: p) }

    // MARK: 旁观（其他屏幕已有选区）

    func becomeBystander() {
        bystander = true
        selection.hoverRect = nil
        hoverResolver?.invalidate()
        needsDisplay = true
    }
    func leaveBystander() { bystander = false; needsDisplay = true }

    // MARK: 坐标换算

    private func screenPoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: snapshot.frame.minX + p.x, y: snapshot.frame.maxY - p.y)
    }
    private func viewRect(fromScreen r: CGRect) -> CGRect {
        CGRect(x: r.minX - snapshot.frame.minX, y: snapshot.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// 两阶段：先同步给出窗口级高亮（永远立刻可见），再由元素级识别异步收紧到对话框。
    /// 用户最差看到的是高亮在几毫秒后缩小一次，不会有卡顿。
    private func updateHover(at p: CGPoint) {
        guard !bystander, !selection.hasSelection else { return }
        let sp = screenPoint(fromView: p)
        guard let hit = session?.windowHit(at: sp, clampTo: snapshot.frame) else {
            selection.hoverRect = bounds
            needsDisplay = true
            return
        }
        selection.hoverRect = viewRect(fromScreen: hit.frame)
        needsDisplay = true
        hoverResolver?.refine(window: hit.frame, at: sp) { [weak self] refined in
            guard let self, !self.bystander, !self.selection.hasSelection else { return }
            let v = self.viewRect(fromScreen: refined)
            guard v != self.selection.hoverRect else { return }
            self.selection.hoverRect = v
            self.needsDisplay = true
        }
    }

    // MARK: 鼠标

    override func mouseEntered(with event: NSEvent) {
        guard !bystander else { return }
        if session?.activeView == nil { window?.makeKey() }
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p)
        cursor(at: p).set()
    }
    override func mouseExited(with event: NSEvent) {
        guard !selection.hasSelection else { return }
        selection.hoverRect = nil
        hoverResolver?.invalidate()
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p)
        cursor(at: p).set()
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
        if case .moving = selection.phase { NSCursor.closedHand.set() }
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
            let hadSelection = selection.hasSelection
            selection.mouseUp(at: p)
            if selection.isSelected {
                layoutToolbar(); toolbar.isHidden = false
            } else if hadSelection {
                // 把手被拖到零宽/零高，选区消失：标注、旁观状态一起清掉
                resetSelection()
            }
        }
        cursor(at: p).set()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if textEditor != nil { commitTextEditor(); return }
        let p = convert(event.locationInWindow, from: nil)
        if bystander {
            // 选区在别的屏幕上：右键清掉它，回到所有屏幕都可框选的状态
            session?.clearSelection()
            updateHover(at: p)
            cursor(at: p).set()
        } else if selection.hasSelection {
            resetSelection()
            updateHover(at: p)
            cursor(at: p).set()
        } else {
            session?.cancel()
        }
    }

    /// 清掉选区和标注，退出工具，通知其他屏幕结束旁观。
    func resetSelection() {
        commitTextEditor()
        selection.clearSelection()
        store.removeAll()
        toolbar.canUndo = false
        toolbar.deselectTool()
        tool = nil
        toolbar.isHidden = true
        session?.selectionDidClear()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: session?.cancel()                                    // Esc
        case 36, 76: if selection.isSelected { finish(save: false) } // Return / Enter
        default:
            let ch = event.charactersIgnoringModifiers?.lowercased()
            if cmd, ch == "z" { undo() }
            else if cmd, ch == "s", selection.isSelected { finish(save: true) }
            // 其他按键直接吞掉：交给 super 会响系统提示音
        }
    }

    // MARK: 光标

    /// 不用 cursorRect（把手区域会互相重叠），改为在鼠标移动时按状态设置。
    private func refreshCursor() {
        guard let window else { return }
        cursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)).set()
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard !bystander, selection.isSelected, let r = selection.rect else { return .crosshair }
        if let tool { return tool == .text && r.contains(p) ? .iBeam : .crosshair }
        if let h = SelectionModel.handle(at: p, of: r) { return Self.resizeCursor(for: h) }
        return r.contains(p) ? .openHand : .crosshair
    }

    private static func resizeCursor(for h: Handle) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch h {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

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
                self.store.append(.text(s, origin: editor.frame.origin, maxWidth: editor.maxWidth, editor.annotationStyle))
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
        if save { session?.save(img, scale: snapshot.scale) } else { session?.complete(with: img, scale: snapshot.scale) }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 冻结底图在下面独立的 FrozenImageView 里，这里只画标注、遮罩和选区装饰

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

    /// 尺寸标签文字：与导出走同一份换算，数字就是 Enter 复制出去的像素数。
    /// Retina 屏幕再标 @2x / @1x，一眼看出这张图是全分辨率还是已缩到屏幕尺寸。
    func sizeLabelText(for r: CGRect) -> String {
        let px = ImageComposer.pixelRect(for: r, scale: snapshot.scale, imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        let scale = snapshot.scale
        guard scale > 1 else { return "\(Int(px.width)) × \(Int(px.height))" }
        let at1x = (session?.exportOptions ?? .current).copyAt1x
        if at1x {
            let (w, h) = Exporter.downscaledSize(px.size, by: scale)
            return "\(w) × \(h) @1x"
        }
        let tag = scale == scale.rounded() ? "\(Int(scale))" : String(format: "%.1f", scale)
        return "\(Int(px.width)) × \(Int(px.height)) @\(tag)x"
    }

    private func drawSizeLabel(for r: CGRect, in ctx: CGContext) {
        let attr = NSAttributedString(string: sizeLabelText(for: r), attributes: [
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
