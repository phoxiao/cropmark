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
    static let columns = 3
    static let cellSize = CGSize(width: 208, height: 158)
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 20
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 60
    /// 超过这么多行就滚动
    static let maxVisibleRows = 3

    private let store: HistoryStore
    private var entries: [HistoryEntry] = []
    private var cells: [HistoryCell] = []
    private(set) var selectedIndex = 0
    private let header = NSTextField(labelWithString: L10n.t("截图历史"))
    private let emptyIcon = NSImageView()
    private let empty = NSTextField(labelWithString: L10n.t("还没有截图"))
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let countLabel = NSTextField(labelWithString: "")
    private let closeButton = HistoryPanelButton()
    private let footer = NSView()
    private let divider = NSBox()
    private(set) var actionButtons: [NSButton] = []

    var onAction: ((HistoryAction, HistoryEntry) -> Void)?
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(store: HistoryStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        header.font = .systemFont(ofSize: 17, weight: .semibold)
        header.textColor = .labelColor
        addSubview(header)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        addSubview(countLabel)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("关闭"))
        closeButton.title = ""
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.setAccessibilityLabel(L10n.t("关闭"))
        closeButton.toolTip = L10n.t("关闭") + " Esc"
        addSubview(closeButton)
        addSubview(footer)
        divider.boxType = .separator
        addSubview(divider)
        for (index, title, symbol, tip) in [
            (0, "", "trash", L10n.t("删除 Delete")),
            (1, L10n.t("保存"), "square.and.arrow.down", L10n.t("保存到文件 ⌘S")),
            (2, L10n.t("编辑"), "pencil", L10n.t("编辑 Enter")),
            (3, L10n.t("复制"), "doc.on.doc", L10n.t("复制 ⌘C")),
        ] {
            let button = HistoryPanelButton(title: title, target: self, action: #selector(performButton(_:)))
            button.style = index == 3 ? .primary : (index == 0 ? .plain : .secondary)
            button.tag = index
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.font = .systemFont(ofSize: 13, weight: index == 3 ? .medium : .regular)
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            footer.addSubview(button)
            actionButtons.append(button)
        }
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        addSubview(empty)
        emptyIcon.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 25, weight: .regular))
        emptyIcon.imageScaling = .scaleNone
        emptyIcon.contentTintColor = .secondaryLabelColor
        addSubview(emptyIcon)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func dismiss() { onClose?() }

    @objc private func performButton(_ sender: NSButton) {
        let actions: [HistoryAction] = [.delete, .save, .edit, .copy]
        trigger(actions[sender.tag], at: selectedIndex)
        if sender.tag == 0 { window?.makeFirstResponder(self) }
    }

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
        let rows = max(1, min((entries.count + Self.columns - 1) / Self.columns, Self.maxVisibleRows))
        let w = Self.padding * 2 + CGFloat(Self.columns) * Self.cellSize.width + CGFloat(Self.columns - 1) * Self.spacing
        let h = Self.headerHeight + Self.padding + CGFloat(rows) * Self.cellSize.height
            + CGFloat(rows - 1) * Self.spacing + Self.footerHeight
        return NSSize(width: w, height: h)
    }

    private func layoutCells() {
        let size = fittingSize
        empty.isHidden = !entries.isEmpty
        emptyIcon.isHidden = empty.isHidden
        scroll.isHidden = entries.isEmpty
        countLabel.stringValue = L10n.t("%d 张", entries.count)
        header.frame = CGRect(x: Self.padding + 2, y: 16, width: header.fittingSize.width, height: 22)
        countLabel.frame = CGRect(x: header.frame.maxX + 10, y: 20, width: countLabel.fittingSize.width, height: 17)
        closeButton.frame = CGRect(x: size.width - Self.padding - 28, y: 13, width: 28, height: 28)
        let top = Self.headerHeight
        let footerY = size.height - Self.footerHeight
        let emptyCenter = (top + footerY - Self.padding) / 2
        emptyIcon.frame = CGRect(x: (size.width - 32) / 2, y: emptyCenter - 28, width: 32, height: 28)
        empty.frame = CGRect(x: 0, y: emptyCenter + 8, width: size.width, height: 20)
        scroll.frame = CGRect(x: Self.padding, y: top, width: size.width - Self.padding * 2,
                              height: footerY - top - Self.padding)
        footer.frame = CGRect(x: 0, y: footerY, width: size.width, height: Self.footerHeight)
        divider.frame = CGRect(x: 0, y: footerY, width: size.width, height: 1)
        actionButtons[0].frame = CGRect(x: Self.padding, y: 14, width: 32, height: 32)
        var right = size.width - Self.padding
        for button in actionButtons.dropFirst().reversed() {
            let width = max(84, button.fittingSize.width + 16)
            right -= width
            button.frame = CGRect(x: right, y: 14, width: width, height: 32)
            right -= 8
        }
        actionButtons.forEach { $0.isEnabled = !entries.isEmpty }
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
        window?.makeFirstResponder(self)
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

/// 一格只显示截图、时间和像素尺寸；操作固定在面板底栏。
final class HistoryCell: NSView {
    static let thumbHeight: CGFloat = 126
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
    private let dimensions: NSTextField

    override var isFlipped: Bool { true }

    init(entry: HistoryEntry, thumbnail: CGImage?) {
        time = NSTextField(labelWithString: Self.relative.localizedString(for: entry.date, relativeTo: Date()))
        dimensions = NSTextField(labelWithString: "\(entry.pixelWidth) × \(entry.pixelHeight)")
        super.init(frame: CGRect(origin: .zero, size: HistoryGridView.cellSize))
        wantsLayer = true
        layer?.cornerRadius = 8

        image.imageScaling = .scaleProportionallyDown
        image.wantsLayer = true
        if let thumbnail {
            image.image = NSImage(cgImage: thumbnail, size: .zero)
        } else {
            image.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
            image.contentTintColor = .secondaryLabelColor
            image.imageScaling = .scaleNone
        }
        addSubview(image)
        time.font = .systemFont(ofSize: 11)
        time.textColor = .secondaryLabelColor
        time.alignment = .left
        addSubview(time)

        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        dimensions.alignment = .right
        addSubview(dimensions)
        image.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
        image.layer?.cornerRadius = 5
        image.layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(time.stringValue + ", " + dimensions.stringValue)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        layout()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        image.frame = CGRect(x: 6, y: 6, width: bounds.width - 12, height: Self.thumbHeight - 6)
        let dimensionWidth = dimensions.fittingSize.width
        dimensions.frame = CGRect(x: bounds.width - dimensionWidth - 8, y: Self.thumbHeight + 6,
                                  width: dimensionWidth, height: 16)
        time.frame = CGRect(x: 8, y: Self.thumbHeight + 6, width: bounds.width - dimensionWidth - 24, height: 16)
        time.lineBreakMode = .byTruncatingTail
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    private func refresh() {
        setAccessibilityValue(isSelected ? 1 : 0)
        layer?.backgroundColor = isSelected ? Palette.accent.withAlphaComponent(0.09).cgColor
            : hovered ? NSColor(white: 0, alpha: 0.05).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 2 : 0
        layer?.borderColor = NSColor(srgbRed: 0.16, green: 0.39, blue: 0.80, alpha: 1).cgColor
        time.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        if event.clickCount == 2 { onAction?(.edit) }
    }
}

/// 统一面板按钮的高度、图标和状态，同时保留 NSButton 的事件与键盘焦点。
private final class HistoryPanelButton: NSButton {
    enum Style { case plain, secondary, primary }
    var style = Style.plain
    private var hoverTracking: NSTrackingArea?
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let primary = style == .primary
        let fill: NSColor
        switch style {
        case .plain:
            fill = isEnabled && (hovered || isHighlighted) ? NSColor(white: 0.88, alpha: 1) : .clear
        case .secondary:
            fill = NSColor(white: isEnabled && hovered ? 0.88 : 0.92, alpha: 1)
        case .primary:
            fill = isEnabled ? NSColor(srgbRed: 0.16, green: 0.39, blue: 0.80, alpha: 1) : NSColor(white: 0.90, alpha: 1)
        }
        let darkening = isEnabled && isHighlighted ? 0.12 : (primary && hovered ? 0.06 : 0)
        (fill.blended(withFraction: darkening, of: .black) ?? fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()

        let foreground: NSColor = isEnabled ? (primary ? .white : .labelColor) : .disabledControlTextColor
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground])
        let textSize = text.size()
        let iconSize: CGFloat = title.isEmpty ? 14 : 15
        let gap: CGFloat = title.isEmpty ? 0 : 6
        let start = (bounds.width - textSize.width - iconSize - gap) / 2
        image?.withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium))?
            .tinted(foreground).draw(in: CGRect(x: start, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize))
        text.draw(at: CGPoint(x: start + iconSize + gap, y: (bounds.height - textSize.height) / 2))
    }
}
