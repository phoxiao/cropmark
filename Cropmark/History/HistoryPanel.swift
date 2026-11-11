import AppKit

enum HistoryAction { case copy, edit, save, delete }

/// 截图历史面板：光标所在屏幕正中的一个浮动面板，缩略图网格，新的在前。
/// 用完就走：做了任一操作（删除除外）、按 Esc、点了别处，面板都会关掉。
@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    private let store: HistoryStore
    private let panel: HistoryPanelWindow
    private let grid: HistoryGridView
    /// 面板关掉了。reason 为 nil 表示是被动关的（Esc、点了别处），要把焦点还回去
    var onClose: (() -> Void)?
    var onAction: ((HistoryAction, HistoryEntry) -> Void)?
    private var closing = false

    init(store: HistoryStore) {
        self.store = store
        grid = HistoryGridView(store: store)
        panel = HistoryPanelWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)   // 和截图工具栏一样恒为浅色
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.addSubview(grid)
        panel.contentView = bg

        grid.onAction = { [weak self] action, entry in self?.perform(action, entry) }
        grid.onClose = { [weak self] in self?.close() }
        store.onChange = { [weak self] in self?.reload() }
        reload()
    }

    var isVisible: Bool { panel.isVisible }
    var window: NSWindow { panel }
    var gridForTesting: HistoryGridView { grid }

    func show() {
        reload()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = panel.frame.size
        let vf = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: (vf.midX - size.width / 2).rounded(), y: (vf.midY - size.height / 2).rounded()))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(grid)
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// 关面板。主动执行操作时由调用方接手焦点，不触发 onClose
    func close(notify: Bool = true) {
        guard !closing else { return }
        closing = true
        store.onChange = nil
        panel.orderOut(nil)
        if notify { onClose?() }
    }

    private func perform(_ action: HistoryAction, _ entry: HistoryEntry) {
        if action == .delete {
            store.delete(entry.id)   // 面板留着，方便连着删
            return
        }
        close(notify: false)
        onAction?(action, entry)
    }

    private func reload() {
        grid.reload()
        let size = grid.fittingSize
        grid.frame = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        var frame = CGRect(origin: panel.frame.origin, size: size)
        if panel.isVisible { frame.origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded()) }
        panel.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // 点了别处就收起。保存框、编辑覆盖层出现之前面板已经先关了，走不到这里
        guard panel.isVisible else { return }
        close()
    }
}

final class HistoryPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 缩略图网格和键盘操作。
@MainActor
final class HistoryGridView: NSView {
    static let columns = 4
    static let cellSize = CGSize(width: 220, height: 166)
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    static let headerHeight: CGFloat = 26
    /// 超过这么多行就滚动
    static let maxVisibleRows = 3

    private let store: HistoryStore
    private var entries: [HistoryEntry] = []
    private var cells: [HistoryCell] = []
    private(set) var selectedIndex = 0
    private let header = NSTextField(labelWithString: L10n.t("截图历史"))
    private let empty = NSTextField(labelWithString: L10n.t("还没有截图"))
    private let scroll = NSScrollView()
    private let content = FlippedView()

    var onAction: ((HistoryAction, HistoryEntry) -> Void)?
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(store: HistoryStore) {
        self.store = store
        super.init(frame: .zero)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor
        addSubview(header)
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        addSubview(empty)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    var entryIDsForTesting: [UUID] { entries.map(\.id) }

    func reload() {
        let previous = entries.indices.contains(selectedIndex) ? entries[selectedIndex].id : nil
        entries = store.entries
        cells.forEach { $0.removeFromSuperview() }
        cells = entries.enumerated().map { i, e in
            let c = HistoryCell(entry: e, thumbnail: store.thumbnail(for: e))
            c.onAction = { [weak self] a in self?.trigger(a, at: i) }
            c.onSelect = { [weak self] in self?.select(i) }
            content.addSubview(c)
            return c
        }
        // 删掉的是选中那条：选中落到原位置上的下一条（删的是最后一条就落到新的最后一条）
        if let previous, let i = entries.firstIndex(where: { $0.id == previous }) { selectedIndex = i }
        selectedIndex = min(selectedIndex, max(entries.count - 1, 0))
        layoutCells()
        refreshSelection()
    }

    override var fittingSize: NSSize {
        if entries.isEmpty { return NSSize(width: 300, height: 120) }
        let cols = min(entries.count, Self.columns)
        let rows = min((entries.count + Self.columns - 1) / Self.columns, Self.maxVisibleRows)
        let w = Self.padding * 2 + CGFloat(cols) * Self.cellSize.width + CGFloat(cols - 1) * Self.spacing
        let h = Self.padding * 2 + Self.headerHeight + CGFloat(rows) * Self.cellSize.height + CGFloat(rows - 1) * Self.spacing
        return NSSize(width: w, height: h)
    }

    private func layoutCells() {
        let size = fittingSize
        empty.isHidden = !entries.isEmpty
        header.isHidden = entries.isEmpty
        scroll.isHidden = entries.isEmpty
        empty.frame = CGRect(x: 0, y: (size.height - 20) / 2, width: size.width, height: 20)
        header.frame = CGRect(x: Self.padding + 2, y: Self.padding - 2, width: size.width - Self.padding * 2, height: 18)
        let top = Self.padding + Self.headerHeight
        scroll.frame = CGRect(x: Self.padding, y: top, width: size.width - Self.padding * 2, height: size.height - top - Self.padding)
        let totalRows = (entries.count + Self.columns - 1) / Self.columns
        content.frame = CGRect(x: 0, y: 0, width: scroll.frame.width,
                               height: max(CGFloat(totalRows) * (Self.cellSize.height + Self.spacing) - Self.spacing, 0))
        for (i, c) in cells.enumerated() {
            let col = i % Self.columns, row = i / Self.columns
            c.frame = CGRect(x: CGFloat(col) * (Self.cellSize.width + Self.spacing),
                             y: CGFloat(row) * (Self.cellSize.height + Self.spacing),
                             width: Self.cellSize.width, height: Self.cellSize.height)
        }
    }

    private func select(_ i: Int) {
        guard entries.indices.contains(i) else { return }
        selectedIndex = i
        refreshSelection()
        cells[i].scrollToVisible(cells[i].bounds)
    }

    private func refreshSelection() {
        for (i, c) in cells.enumerated() { c.isSelected = i == selectedIndex }
    }

    private func trigger(_ action: HistoryAction, at i: Int) {
        guard entries.indices.contains(i) else { return }
        selectedIndex = i
        onAction?(action, entries[i])
    }

    func triggerForTesting(_ action: HistoryAction) { trigger(action, at: selectedIndex) }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let ch = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case 53: onClose?()                                     // Esc
        case 123: select(selectedIndex - 1)                     // ←
        case 124: select(selectedIndex + 1)                     // →
        case 126: select(selectedIndex - Self.columns)          // ↑
        case 125: select(selectedIndex + Self.columns)          // ↓
        case 36, 76: trigger(.edit, at: selectedIndex)          // Return / Enter
        case 51, 117: trigger(.delete, at: selectedIndex)       // Delete / Fn+Delete
        default:
            if cmd, ch == "c" { trigger(.copy, at: selectedIndex) }
            else if cmd, ch == "s" { trigger(.save, at: selectedIndex) }
            else if cmd, ch == "w" { onClose?() }
            // 其他按键吞掉，交给 super 会响提示音
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 一格：缩略图 + 相对时间，悬停或选中时右上角出现四个操作按钮。
final class HistoryCell: NSView {
    static let thumbHeight: CGFloat = 136
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    var onAction: ((HistoryAction) -> Void)?
    var onSelect: (() -> Void)?
    var isSelected = false { didSet { refresh() } }
    private var hovered = false { didSet { refresh() } }

    private let image = NSImageView()
    private let time: NSTextField
    private let actions = NSStackView()

    override var isFlipped: Bool { true }

    init(entry: HistoryEntry, thumbnail: CGImage?) {
        time = NSTextField(labelWithString: Self.relative.localizedString(for: entry.date, relativeTo: Date()))
        super.init(frame: CGRect(origin: .zero, size: HistoryGridView.cellSize))
        wantsLayer = true
        layer?.cornerRadius = 8

        image.imageScaling = .scaleProportionallyDown
        image.wantsLayer = true
        if let thumbnail { image.image = NSImage(cgImage: thumbnail, size: .zero) }
        addSubview(image)
        time.font = .systemFont(ofSize: 11)
        time.textColor = .secondaryLabelColor
        time.alignment = .center
        addSubview(time)

        let wrap = actions
        wrap.orientation = .horizontal
        wrap.spacing = 0
        wrap.edgeInsets = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 2)
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.95).cgColor
        wrap.layer?.cornerRadius = 6
        wrap.layer?.shadowColor = NSColor.black.cgColor
        wrap.layer?.shadowOpacity = 0.18
        wrap.layer?.shadowRadius = 3
        wrap.layer?.shadowOffset = CGSize(width: 0, height: 1)
        for (action, symbol, tip) in [
            (HistoryAction.copy, "doc.on.doc", L10n.t("复制 ⌘C")),
            (.edit, "pencil", L10n.t("编辑 Enter")),
            (.save, "square.and.arrow.down", L10n.t("保存到文件 ⌘S")),
            (.delete, "trash", L10n.t("删除 Delete")),
        ] {
            let b = ToolButton(symbol: symbol, tooltip: tip) { [weak self] in self?.onAction?(action) }
            if action == .delete { b.tint = .systemRed }
            wrap.addArrangedSubview(b)
        }
        addSubview(wrap)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        layout()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        image.frame = CGRect(x: 6, y: 6, width: bounds.width - 12, height: Self.thumbHeight - 6)
        time.frame = CGRect(x: 4, y: Self.thumbHeight + 4, width: bounds.width - 8, height: 16)
        let s = actions.fittingSize
        actions.frame = CGRect(x: bounds.width - s.width - 10, y: 10, width: s.width, height: s.height)
    }

    private func refresh() {
        actions.isHidden = !(hovered || isSelected)
        layer?.backgroundColor = isSelected ? Palette.accent.withAlphaComponent(0.14).cgColor
            : hovered ? NSColor(white: 0, alpha: 0.05).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = Palette.accent.cgColor
    }

    var areActionsVisibleForTesting: Bool { !actions.isHidden }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        if event.clickCount == 2 { onAction?(.edit) }
    }
}
