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
    /// 悬停阶段右上角的「截图历史」按钮。只在光标所在的这块屏幕、还没框选时出现
    private var historyButton: HistoryButton?
    private var pointerInside = false

    private var tool: ToolKind?
    private var style = Style(color: Palette.colors[0], thickness: .medium)
    private var inProgress: Annotation.Shape?
    private var drawAnchor: CGPoint?
    /// 按下时脚底下踩着哪条标注。松手时若画出来的东西太小，说明这一下其实是点选，把选中还给它
    private var downHit: Annotation.ID?
    private var textEditor: TextEditorOverlay?
    /// 正在被重新编辑的那条文字：渲染时跳过它，免得和输入框里的字叠成重影
    private var editingTextID: Annotation.ID?
    /// 标注的选中与拖拽。画完自动选中，之后点它的边线可重新选中
    private var editor: AnnotationEditor
    private var bystander = false
    /// 门控用的修饰键当前是否按着。记下来是为了知道它什么时候翻转——那一帧即使高亮矩形没变也要重画。
    private var dialogModifierHeld = false
    /// 最后一次算悬停用的视图坐标。修饰键变化事件不带鼠标位置，靠它重算；
    /// 光标移出本屏或进入旁观时清掉，免得拿一个早已失效的点去做命中测试。
    private var lastHoverPoint: CGPoint?
    private var pixelCache: [Thickness: CGImage] = [:]
    private lazy var renderer = AnnotationRenderer(screenSize: bounds.size) { [weak self] t in self?.pixelated(t) }

    private static let dimColor = NSColor(white: 0, alpha: 0.45)
    /// 尺寸标签和悬停提示共用的胶囊底色
    private static let capsuleColor = NSColor(white: 0, alpha: 0.7).cgColor
    /// 按住它才做块级识别（应用内的对话框、面板、卡片）。常开太灵敏：
    /// 想框整个窗口时高亮总在自己缩小，反而要多操作一步。
    private static let dialogModifier: NSEvent.ModifierFlags = .command

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(snapshot: ScreenSnapshot, session: CaptureSession) {
        self.snapshot = snapshot
        self.session = session
        let b = CGRect(origin: .zero, size: snapshot.frame.size)
        self.selection = SelectionModel(bounds: b, scale: snapshot.scale)
        self.hoverResolver = session.elementDetection.resolver(for: snapshot)
        self.editor = AnnotationEditor(geometry: .appKit(), scale: snapshot.scale)
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
        toolbar.onStyleChange = { [weak self] s in self?.applyStyle(s) }
        toolbar.onAction = { [weak self] a in
            guard let self else { return }
            switch a {
            case .undo: self.undo()
            case .save: self.finish(save: true)
            case .cancel: self.session?.cancel()
            case .done: self.finish(save: false)
            }
        }
        if let edit = session.editContext {
            // 重新编辑历史截图：选区就是那张图，标注从存档载入，工具栏直接出来
            selection.lock(to: edit.placement)
            store.load(edit.viewAnnotations)
            toolbar.isHidden = false
            layoutToolbar()
        } else {
            selection.hoverRect = b
            if session.onOpenHistory != nil {
                let button = HistoryButton(tooltip: session.historyTooltip) { [weak self] in self?.session?.openHistory() }
                button.frame = HistoryButton.frame(in: b, topInset: snapshot.screen.frame.maxY - snapshot.screen.visibleFrame.maxY)
                addSubview(button)
                historyButton = button
                pointerInside = snapshot.frame.contains(NSEvent.mouseLocation)
                refreshHistoryButton()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refreshHistoryButton() {
        historyButton?.isHidden = bystander || selection.hasSelection || !pointerInside
    }

    // MARK: 测试钩子

    var currentSelection: CGRect? { selection.rect }
    var isToolbarVisible: Bool { !toolbar.isHidden }
    var annotationCount: Int { store.items.count }
    var annotationsForTesting: [Annotation] { store.items }
    var isBystander: Bool { bystander }
    var hoverRectForTesting: CGRect? { selection.hoverRect }
    func selectToolForTesting(_ t: ToolKind?) { toolbar.selectTool(t) }
    func cursorForTesting(at p: CGPoint) -> NSCursor { cursor(at: p) }
    var selectedAnnotationForTesting: Annotation? { selectedAnnotation }
    var canRedoForTesting: Bool { store.canRedo }
    func applyStyleForTesting(_ s: Style) { applyStyle(s) }
    var visibleAnnotationCountForTesting: Int { visibleItems.count }
    var isHistoryButtonVisible: Bool { historyButton.map { !$0.isHidden } ?? false }
    var historyButtonFrame: CGRect? { historyButton?.frame }
    func setPointerInsideForTesting(_ v: Bool) { pointerInside = v; refreshHistoryButton() }

    // MARK: 旁观（其他屏幕已有选区）

    func becomeBystander() {
        bystander = true
        selection.hoverRect = nil
        lastHoverPoint = nil
        hoverResolver?.invalidate()
        refreshHistoryButton()
        needsDisplay = true
    }
    func leaveBystander() { bystander = false; refreshHistoryButton(); needsDisplay = true }

    // MARK: 坐标换算

    private func screenPoint(fromView p: CGPoint) -> CGPoint {
        CGPoint(x: snapshot.frame.minX + p.x, y: snapshot.frame.maxY - p.y)
    }
    private func viewRect(fromScreen r: CGRect) -> CGRect {
        CGRect(x: r.minX - snapshot.frame.minX, y: snapshot.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// 两阶段：先同步给出窗口级高亮（永远立刻可见），按住 ⌘ 时再由元素级识别异步收紧到对话框。
    /// 用户最差看到的是高亮在几毫秒后缩小一次，不会有卡顿。
    private func updateHover(at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard !bystander, !selection.hasSelection else { return }
        lastHoverPoint = p
        let held = modifiers.contains(Self.dialogModifier)
        let gateChanged = held != dialogModifierHeld
        dialogModifierHeld = held

        let sp = screenPoint(fromView: p)
        let hit = session?.windowHit(at: sp, clampTo: snapshot.frame)
        // 同一个矩形不重复标脏：draw 不看 dirtyRect，每帧都要把「整屏减去洞」的遮罩重铺一遍，
        // 光标在同一个窗口里晃的那几十帧全是白干。门控翻转那一帧例外，底部提示要跟着出现/消失
        let rect = hit.map { viewRect(fromScreen: $0.frame) } ?? bounds
        if gateChanged || rect != selection.hoverRect {
            selection.hoverRect = rect
            needsDisplay = true
        }

        guard let hit, held, let resolver = hoverResolver else {
            // 松键之前发出的那次查询还在飞：不作废的话它回来会把高亮又缩回去，
            // 而且之后不会再有事件来清一次
            hoverResolver?.invalidate()
            return
        }
        if !Preferences.didUseDialogModifier { Preferences.didUseDialogModifier = true }
        resolver.refine(window: hit.frame, at: sp) { [weak self] refined in
            guard let self, !self.bystander, !self.selection.hasSelection else { return }
            let v = self.viewRect(fromScreen: refined)
            guard v != self.selection.hoverRect else { return }
            self.selection.hoverRect = v
            self.needsDisplay = true
        }
    }

    // MARK: 鼠标

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshHistoryButton()
        guard !bystander else { return }
        if session?.activeView == nil { window?.makeKey() }
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p, modifiers: event.modifierFlags)
        cursor(at: p).set()
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        refreshHistoryButton()
        guard !selection.hasSelection else { return }
        selection.hoverRect = nil
        lastHoverPoint = nil
        hoverResolver?.invalidate()
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateHover(at: p, modifiers: event.modifierFlags)
        cursor(at: p).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard !bystander else { return }
        let p = convert(event.locationInWindow, from: nil)
        if textEditor != nil { commitTextEditor(); return }

        guard selection.isSelected, let r = selection.rect else { beginSelectionGesture(at: p); return }
        editor.limit = r

        // ① 选中标注的把手最优先。工具还亮着也要能拉——"画歪了立刻拉一下"是同一个动作的延续，
        //    被它吃掉的只是几个画出来的小圆点，用户看得见
        if let a = selectedAnnotation, let h = editor.geometry.handle(at: p, of: a) {
            store.beginDrag()
            editor.beginResizing(a, handle: h)
            return
        }
        // ② 工具亮着就在选区内画新的：亮着的工具是一个显式的模式声明。
        //    按住 ⌘ 让路，给"就是想改旧框"留个不用先关工具的出口
        //    （⌘ 在悬停阶段是另一件事——识别对话框，见 dialogModifier；两个阶段互斥，不打架）
        if let tool, r.contains(p), !event.modifierFlags.contains(.command) {
            // 先记下脚底下踩着谁，但别动选中态：这一下到底算"画新的"还是算"点选"，
            // 要等松手时看画出来的东西够不够大才知道
            downHit = editor.geometry.topmost(at: p, in: store.items)?.id
            beginDrawing(tool, at: p, in: r)
            return
        }
        // ③ 无工具时选区把手优先于标注本体。标注整块可点之后，一个盖住选区角的大框
        //    会让选区彻底拉不动；把手是画出来的白点，用户看得见就必须点得中
        if tool == nil, !selection.isLocked, SelectionModel.handle(at: p, of: r) != nil {
            beginSelectionGesture(at: p)
            return
        }
        // ④ 点中某条标注：选中它并立刻开始拖动，一次按下完成两件事
        if r.contains(p), let a = editor.geometry.topmost(at: p, in: store.items) {
            if event.clickCount == 2 {
                // 双击文字进重编辑；双击别的标注仍然完成截图——标注整块可点之后会盖住
                // 大片选区，不放行的话 README 里写的"双击完成"就等于没了
                if case .text = a.shape { select(a.id); beginTextEditing(a) } else { finish(save: false) }
                return
            }
            store.beginDrag()
            editor.beginMoving(a, grab: p)
            selectionDidChange()
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        // ⑤ 点在空白处：取消选中，回到选区自己的手势
        select(nil)
        if event.clickCount == 2, r.contains(p) { finish(save: false); return }
        beginSelectionGesture(at: p)
    }

    /// 选区自己的按下手势：新建、整体移动、拉把手。
    private func beginSelectionGesture(at p: CGPoint) {
        guard !selection.isLocked else { return }
        let hadSelection = selection.hasSelection
        selection.mouseDown(at: p)
        if case .moving = selection.phase { NSCursor.closedHand.set() }
        if case .dragging = selection.phase {
            // 重新框选：丢弃旧标注
            clearAnnotations()
            toolbar.isHidden = true
            if !hadSelection { session?.selectionDidBegin(on: self) }
        } else {
            toolbar.isHidden = true
        }
        refreshHistoryButton()
        needsDisplay = true
    }

    // MARK: 标注的选中与编辑

    private var selectedAnnotation: Annotation? { editor.selected.flatMap { store.item(id: $0) } }

    /// 选中/取消选中一条标注
    private func select(_ id: Annotation.ID?) {
        // 这条标注可能已经不在了（被撤销掉、被右键清掉），那就当没选中。
        // 否则工具栏会卡在"有选中"的假状态：选项行展开着，却既没有虚线框也删不掉
        let id = id.flatMap { store.item(id: $0) != nil ? $0 : nil }
        guard editor.selected != id else { return }
        editor.select(id)
        selectionDidChange()
        needsDisplay = true
    }

    /// 选中的标注变了：工具栏要跟着显示它的样式
    private func selectionDidChange() {
        toolbar.hasSelectedAnnotation = editor.selected != nil
        if let a = selectedAnnotation {
            style = a.style
            toolbar.showStyle(a.style, colorsEnabled: !a.isMosaic)
        }
        layoutToolbar()   // 选项行的显隐会改面板高度
    }

    /// 撤销可能把选中的那条撤没了，虚线框不能还留在空白处
    private func syncSelection() {
        if let id = editor.selected, store.item(id: id) == nil { select(nil) }
    }

    /// 清空标注，连同选中态和正在进行的编辑。
    /// 三个调用点必须走同一条路，漏掉就会出现"选中一条已经不存在的标注"
    private func clearAnnotations() {
        store.removeAll()
        editor.select(nil)
        editor.endDrag()
        selectionDidChange()
        refreshToolbarState()
    }

    /// 工具栏改了颜色/粗细：既是下一条要画的样式，也直接作用在当前选中的那条上。
    private func applyStyle(_ s: Style) {
        style = s
        textEditor?.apply(style: s)        // 正在输入的文字
        guard let id = editor.selected else { return }
        store.update(id: id) { $0.style = s }   // 占一条撤销
        refreshToolbarState()
        needsDisplay = true
    }

    private func continueEditing(to p: CGPoint, shift: Bool) {
        guard let id = editor.selected, let a = editor.dragged(to: p, shift: shift) else { return }
        store.replace(id: id, with: a)
    }

    private func deleteSelected() {
        guard let id = editor.selected else { return }
        store.remove(id: id)
        select(nil)
        refreshToolbarState()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !bystander else { return }
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        if editor.isDragging {
            continueEditing(to: p, shift: shift)
        } else if inProgress != nil || drawAnchor != nil {
            select(nil)        // 真的开始画了，旧的选中让位（guard 守着，只有第一帧真执行）
            continueDrawing(to: p, shift: shift)
        } else {
            selection.mouseDragged(to: p)
            refreshHistoryButton()
        }
        dragCursor().set()
        needsDisplay = true
    }

    /// 拖拽中的光标。拉伸拖过对边后把手会变成镜像，光标要跟着翻，否则方向是反的。
    private func dragCursor() -> NSCursor {
        if let a = selectedAnnotation, let h = editor.liveHandle(of: a) { return Self.cursor(for: h) }
        if editor.isDragging { return .closedHand }
        if let h = selection.liveHandle { return Self.resizeCursor(for: h) }
        if case .moving = selection.phase { return .closedHand }
        return NSCursor.current
    }

    override func mouseUp(with event: NSEvent) {
        guard !bystander else { return }
        let p = convert(event.locationInWindow, from: nil)
        if editor.isDragging {
            continueEditing(to: p, shift: event.modifierFlags.contains(.shift))
            editor.endDrag()
            store.endDrag()      // 整段拖动合成一条撤销；按下没动就松开不记
            refreshToolbarState()
        } else if inProgress != nil || drawAnchor != nil {
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
            refreshHistoryButton()
        }
        cursor(at: p).set()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if textEditor != nil { commitTextEditor(); return }
        // 编辑历史截图时没有「重新框选」可言，右键不做事，免得一下丢掉改了一半的标注
        if selection.isLocked { return }
        let p = convert(event.locationInWindow, from: nil)
        if bystander {
            // 选区在别的屏幕上：右键清掉它，回到所有屏幕都可框选的状态
            session?.clearSelection()
            updateHover(at: p, modifiers: event.modifierFlags)
            cursor(at: p).set()
        } else if selection.hasSelection {
            resetSelection()
            updateHover(at: p, modifiers: event.modifierFlags)
            cursor(at: p).set()
        } else {
            session?.cancel()
        }
    }

    /// 清掉选区和标注，退出工具，通知其他屏幕结束旁观。
    func resetSelection() {
        commitTextEditor()
        selection.clearSelection()
        clearAnnotations()
        toolbar.deselectTool()
        tool = nil
        toolbar.isHidden = true
        session?.selectionDidClear()
        refreshHistoryButton()
        needsDisplay = true
    }

    /// 按下 / 松开 ⌘ 时没有鼠标事件可用，就拿最后一次悬停的点重算：光标只要在本屏移动过，
    /// 那个点就是它现在的位置。无关的修饰键也会走到这里，但重算后矩形没变就不会重画。
    override func flagsChanged(with event: NSEvent) {
        guard let p = lastHoverPoint else { return }
        updateHover(at: p, modifiers: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: session?.cancel()                                    // Esc
        case 36, 76: if selection.isSelected { finish(save: false) } // Return / Enter
        case 51, 117: deleteSelected()                                // Delete / Fn+Delete
        default:
            let ch = event.charactersIgnoringModifiers?.lowercased()
            if cmd, ch == "z" { event.modifierFlags.contains(.shift) ? redo() : undo() }
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
        if let b = historyButton, !b.isHidden, b.frame.contains(p) { return .arrow }
        let locked = selection.isLocked
        guard !bystander, selection.isSelected, let r = selection.rect else { return .crosshair }
        // 顺序要和 mouseDown 一致，否则光标会承诺一件点下去不会发生的事
        if let a = selectedAnnotation, let h = editor.geometry.handle(at: p, of: a) { return Self.cursor(for: h) }
        if tool == nil, !locked, let h = SelectionModel.handle(at: p, of: r) { return Self.resizeCursor(for: h) }
        guard r.contains(p) else { return locked ? .arrow : .crosshair }
        if let tool { return tool == .text ? .iBeam : .crosshair }
        // 锁定的选区挪不动，只有压着标注时才是手形
        if locked { return editor.geometry.topmost(at: p, in: store.items) != nil ? .openHand : .arrow }
        // 选区内无工具：压着标注是"抓标注"，空白是"挪选区"，都是手形，不用分
        return .openHand
    }

    private static func cursor(for h: AnnotationHandle) -> NSCursor {
        switch h {
        case .box(let b): return resizeCursor(for: b)
        case .start, .end: return .crosshair   // 在精确定位一个端点
        }
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
        case .topLeft, .bottomRight: return nwseCursor
        case .topRight, .bottomLeft: return neswCursor
        }
    }

    /// macOS 15 之前没有公开的对角调整光标，系统 API 只给了上下左右四个方向。
    /// 小标注上边中点把手会被砍掉、只剩四个角，没有方向提示就很难用，所以自绘一个。
    /// 不用私有的 _windowResize… 系列：为一个过渡期的兼容问题引入未公开 API 不划算。
    static let nwseCursor = makeDiagonalCursor(rotation: -.pi / 4)
    static let neswCursor = makeDiagonalCursor(rotation: .pi / 4)

    /// 白描边的黑色双向箭头，转到指定角度。描边是为了在深色内容上也看得清。
    static func makeDiagonalCursor(rotation: CGFloat) -> NSCursor {
        let side: CGFloat = 24
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: side / 2, y: side / 2)
            ctx.rotate(by: rotation)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -5, y: 0))
            path.addLine(to: CGPoint(x: 5, y: 0))
            for dir in [CGFloat(-1), 1] {          // 两端各一个三角头
                path.move(to: CGPoint(x: dir * 9, y: 0))
                path.addLine(to: CGPoint(x: dir * 4, y: -4))
                path.addLine(to: CGPoint(x: dir * 4, y: 4))
                path.closeSubpath()
            }
            ctx.setLineJoin(.round)
            ctx.setLineWidth(3)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    // MARK: 绘制标注

    private func beginDrawing(_ tool: ToolKind, at p: CGPoint, in r: CGRect) {
        switch tool {
        case .rect, .ellipse, .arrow:
            drawAnchor = p
        case .pen:
            inProgress = .pen([p])
        case .mosaic:
            inProgress = .mosaic([p])
        case .text:
            let field = TextEditorOverlay.make(at: p, style: style, maxWidth: r.maxX - p.x)
            field.onCommit = { [weak self, weak field] s in
                guard let self, let field else { return }
                guard !s.isEmpty else { self.removeTextEditor(); return }   // 新建时空内容就是不留东西
                let a = Annotation(shape: .text(s, origin: field.frame.origin, maxWidth: field.maxWidth),
                                   style: field.annotationStyle)
                self.store.append(a)
                self.select(a.id)
                self.refreshToolbarState()
                self.removeTextEditor()
            }
            field.onCancel = { [weak self] in self?.removeTextEditor() }
            addSubview(field)
            textEditor = field
            window?.makeFirstResponder(field)
        }
    }

    /// 重新编辑一条已提交的文字：原位打开输入框，内容预填。
    private func beginTextEditing(_ a: Annotation) {
        guard case .text(let text, let origin, let maxWidth) = a.shape else { return }
        let field = TextEditorOverlay.make(at: origin, style: a.style, maxWidth: maxWidth, text: text)
        editingTextID = a.id
        field.onCommit = { [weak self, weak field] s in
            guard let self, let field else { return }
            if s.isEmpty {
                self.store.remove(id: a.id)      // 重编辑时清空内容，就是要删掉这一条
                self.select(nil)
            } else {
                self.store.update(id: a.id) {
                    $0.shape = .text(s, origin: field.frame.origin, maxWidth: field.maxWidth)
                    $0.style = field.annotationStyle
                }
            }
            self.refreshToolbarState()
            self.finishTextEditing()
        }
        field.onCancel = { [weak self] in self?.finishTextEditing() }   // Esc：原样保留
        addSubview(field)
        textEditor = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func finishTextEditing() {
        editingTextID = nil
        removeTextEditor()
    }

    private func continueDrawing(to p: CGPoint, shift: Bool) {
        let q = clampToSelection(p)
        if let a = drawAnchor, let tool {
            switch tool {
            case .rect: inProgress = .rect(shift ? .square(anchor: a, drag: q) : SelectionModel.normalized(a, q))
            case .ellipse: inProgress = .ellipse(shift ? .square(anchor: a, drag: q) : SelectionModel.normalized(a, q))
            case .arrow: inProgress = .arrow(from: a, to: shift ? ArrowGeometry.snapped(from: a, to: q) : q)
            default: break
            }
        } else if case .pen(var pts) = inProgress {
            pts.append(q); inProgress = .pen(pts)
        } else if case .mosaic(var pts) = inProgress {
            pts.append(q); inProgress = .mosaic(pts)
        }
    }

    private func endDrawing(at p: CGPoint, shift: Bool) {
        continueDrawing(to: p, shift: shift)
        defer { inProgress = nil; drawAnchor = nil; downHit = nil }
        guard let shape = inProgress else { return }
        // 太小就丢弃：多半根本不是在画，而是点了一下。
        // 这时把选中还给脚底下那条标注——点在标注上就选中它，点空白才是取消选中
        switch shape {
        case .rect(let r), .ellipse(let r):
            guard r.width >= 2, r.height >= 2 else { select(downHit); return }
        case .arrow(let f, let t):
            guard hypot(t.x - f.x, t.y - f.y) >= 3 else { select(downHit); return }
        default: break
        }
        let a = Annotation(shape: shape, style: style)
        store.append(a)
        select(a.id)              // 画完立刻选中，发现画歪了可以马上拉
        refreshToolbarState()
    }

    /// 钳进选区并吸附到像素网格。不吸附的话，画完再去拉把手会有半个像素的跳变
    private func clampToSelection(_ p: CGPoint) -> CGPoint {
        guard let r = selection.rect else { return p }
        let q = CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
        let s = snapshot.scale
        return CGPoint(x: (q.x * s).rounded() / s, y: (q.y * s).rounded() / s)
    }

    private func undo() {
        commitTextEditor()
        store.undo()
        syncSelection()
        refreshToolbarState()
        needsDisplay = true
    }

    private func redo() {
        commitTextEditor()
        store.redo()
        syncSelection()
        refreshToolbarState()
        needsDisplay = true
    }

    /// 撤销状态只有一个真相来源：store 的撤销栈
    private func refreshToolbarState() { toolbar.canUndo = store.canUndo }

    /// 正在被重新编辑的那条先不画：输入框是透明的，不藏起来就会和框里的字叠成重影
    private var visibleItems: [Annotation] {
        guard let id = editingTextID else { return store.items }
        return store.items.filter { $0.id != id }
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
        // 编辑历史截图时按底图块化，块的大小和位置才和导出一致
        let img = session?.editContext.map { $0.pixelatedCanvas(t) }
            ?? Mosaic.pixelate(snapshot.image, blockPixels: Int(t.mosaicBlock * snapshot.scale))
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
        guard let r = selection.rect, r.width >= 1, r.height >= 1, let session else { return }
        let img: CGImage, scale: CGFloat, archive: HistoryArchive?
        if let edit = session.editContext {
            // 回到底图坐标系按原始像素合成：缩小显示、换了倍率的屏幕都不影响成品
            let items = store.items.applying(edit.toBase)
            guard let out = HistoryComposer.compose(base: edit.base, scale: edit.entry.scale, annotations: items) else {
                session.cancel(); return
            }
            img = out; scale = edit.entry.scale
            archive = HistoryArchive(base: edit.base, scale: scale, annotations: items, replacing: edit.entry.id)
        } else {
            guard let out = ImageComposer.compose(snapshot: snapshot, selection: r, annotations: store.items, renderer: renderer) else {
                session.cancel(); return
            }
            img = out; scale = snapshot.scale
            archive = session.history.flatMap { _ in historyArchive(selection: r) }
        }
        if save { session.save(img, scale: scale, archive: archive) } else { session.complete(with: img, scale: scale, archive: archive) }
    }

    /// 新截图的存档：选区里不带标注的底图，标注平移到以选区左上角为原点
    private func historyArchive(selection r: CGRect) -> HistoryArchive? {
        guard let base = ImageComposer.compose(snapshot: snapshot, selection: r, annotations: [], renderer: renderer) else { return nil }
        let px = ImageComposer.pixelRect(for: r, scale: snapshot.scale, imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        let origin = CGPoint(x: px.minX / snapshot.scale, y: px.minY / snapshot.scale)
        let items = store.items.applying(CGAffineTransform(translationX: -origin.x, y: -origin.y))
        return HistoryArchive(base: base, scale: snapshot.scale, annotations: items, replacing: nil)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 冻结底图在下面独立的 FrozenImageView 里，这里只画标注、遮罩和选区装饰

        if let r = selection.rect, !r.isEmpty {
            ctx.saveGState()
            ctx.clip(to: r)
            renderer.draw(visibleItems, in: ctx)
            if let shape = inProgress { renderer.draw(shape, style: style, in: ctx) }
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

        if selection.hasSelection, tool == nil, !selection.isLocked {
            ctx.setFillColor(NSColor.white.cgColor)
            for (_, hr) in SelectionModel.handleRects(of: hole) {
                ctx.fillEllipse(in: hr)
                ctx.strokeEllipse(in: hr)
            }
        }

        if !selection.isLocked, selection.hasSelection || selection.hoverRect != nil {
            drawSizeLabel(for: hole, in: ctx)
        }
        if let a = selectedAnnotation, let sel = selection.rect {
            drawSelectionChrome(for: a, within: sel, in: ctx)
        }
        if shouldShowDialogHint { drawDialogHint(in: ctx) }
    }

    /// 只在悬停阶段提示，而且只提示到用户真的按过一次 ⌘ 为止——
    /// 这是个每天用几十次的工具，学会之后还天天弹一条就是噪音了。
    /// 高亮是整屏（没命中窗口）时不提示：那种位置按 ⌘ 也没东西可收紧。
    private var shouldShowDialogHint: Bool {
        guard !bystander, !selection.hasSelection, !dialogModifierHeld,
              let hover = selection.hoverRect, hover != bounds,
              hoverResolver != nil, !Preferences.didUseDialogModifier
        else { return false }
        return true
    }

    /// 提示的文字、胶囊、文字落点整个会话都不变（覆盖视图的 bounds 是固定的那块屏幕），
    /// 建一次存着：不然每帧都要查一次本地化表、找一次字体、把同一句话重新排版两遍。
    private lazy var dialogHint: (text: NSAttributedString, box: CGRect, textAt: CGPoint) = {
        let text = NSAttributedString(string: L10n.t("按住 ⌘ 识别对话框"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let pad = CGSize(width: 12, height: 7)
        let size = text.size()
        // 底部居中，离底边 40 点
        let origin = CGPoint(x: ((bounds.width - size.width) / 2).rounded(),
                             y: bounds.maxY - 40 - size.height - pad.height)
        let box = CGRect(x: origin.x - pad.width, y: origin.y - pad.height,
                         width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        return (text, box, origin)
    }()

    /// 和尺寸标签同款的深色胶囊，圆角拉满成药丸形，和那个方角标签一眼分得开。
    private func drawDialogHint(in ctx: CGContext) {
        drawCapsule(dialogHint.text, in: dialogHint.box, corner: dialogHint.box.height / 2,
                    textAt: dialogHint.textAt, in: ctx)
    }

    /// 深色圆角胶囊 + 白字。翻转坐标系里画 NSAttributedString 要临时换一个 NSGraphicsContext，
    /// 这套小花招只留一份，调用方只管把盒子放在哪。
    private func drawCapsule(_ attr: NSAttributedString, in box: CGRect, corner: CGFloat,
                             textAt: CGPoint, in ctx: CGContext) {
        ctx.setFillColor(Self.capsuleColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.fillPath()
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        attr.draw(at: textAt)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 选中标注的装饰：外扩的虚线框 + 把手。
    /// 把手用反色（强调色实心 + 白描边），和选区把手（白底 + 强调色描边）反过来——
    /// 标注贴着选区边缘时两套把手会挨在一起，颜色反过来才一眼分得清哪个是哪个。
    /// 不放进上面 clip 到选区的那段里，否则贴边标注的把手会被裁掉。
    private func drawSelectionChrome(for a: Annotation, within sel: CGRect, in ctx: CGContext) {
        let box = editor.geometry.bounds(of: a).insetBy(dx: -3, dy: -3)
        guard box.intersects(sel) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // 先用半透明白打底，深色浅色内容上都看得见；再叠强调色虚线，和标注自己的实线区分开
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.setLineWidth(2.5)
        ctx.stroke(box)
        ctx.setStrokeColor(Palette.accent.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(box)
        ctx.setLineDash(phase: 0, lengths: [])

        ctx.setFillColor(Palette.accent.cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor)
        let d = HandleLayout.size - 1
        for (_, c) in editor.geometry.handles(of: a) {
            let hr = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            ctx.fillEllipse(in: hr)
            ctx.strokeEllipse(in: hr)
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
        drawCapsule(attr, in: bg, corner: 4, textAt: CGPoint(x: bg.minX + pad, y: bg.minY + pad / 2), in: ctx)
    }
}
