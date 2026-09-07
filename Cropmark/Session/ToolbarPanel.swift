import AppKit

/// 工具栏与二级面板的布局计算（纯函数，可测）。
enum ToolbarPlacement {
    static let gap: CGFloat = 8
    /// 优先放选区下方，放不下放上方，再放不下贴在选区内部底边。右对齐选区，整体不出屏。
    static func frame(selection: CGRect, size: CGSize, bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.maxY + gap)
        if origin.y + size.height > bounds.maxY {
            origin.y = selection.minY - gap - size.height
            if origin.y < bounds.minY {
                origin.y = selection.maxY - gap - size.height
            }
        }
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }
}

enum ToolbarAction { case undo, save, cancel, done }

/// 截图工具栏：一行工具/操作按钮，选中绘图工具时下方展开粗细与颜色。
final class ToolbarPanel: NSView {
    var onSelectTool: ((ToolKind?) -> Void)?
    var onAction: ((ToolbarAction) -> Void)?
    var onStyleChange: ((Style) -> Void)?

    private(set) var style = Style(color: Palette.colors[0], thickness: .medium)
    private(set) var selectedTool: ToolKind?

    private let mainRow = NSStackView()
    private let optionRow = NSStackView()
    private var toolButtons: [ToolKind: ToolButton] = [:]
    private var thicknessButtons: [ToolButton] = []
    private var colorButtons: [ToolButton] = []
    private var optionSeparator: Separator!
    private var undoButton: ToolButton!

    static let rowHeight: CGFloat = 36
    static let optionRowHeight: CGFloat = 32

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.97).cgColor
        layer?.cornerRadius = 8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.masksToBounds = false
        buildRows()
        updateVisibility()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildRows() {
        for row in [mainRow, optionRow] {
            row.orientation = .horizontal
            row.spacing = 2
            row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
        }
        for tool in ToolKind.allCases {
            let b = ToolButton(symbol: tool.symbol, tooltip: tool.title) { [weak self] in self?.toggleTool(tool) }
            toolButtons[tool] = b
            mainRow.addArrangedSubview(b)
        }
        mainRow.addArrangedSubview(Separator())
        undoButton = ToolButton(symbol: "arrow.uturn.backward", tooltip: "撤销 ⌘Z") { [weak self] in self?.onAction?(.undo) }
        mainRow.addArrangedSubview(undoButton)
        mainRow.addArrangedSubview(Separator())
        mainRow.addArrangedSubview(ToolButton(symbol: "square.and.arrow.down", tooltip: "保存到文件") { [weak self] in self?.onAction?(.save) })
        let cancel = ToolButton(symbol: "xmark", tooltip: "取消 Esc") { [weak self] in self?.onAction?(.cancel) }
        cancel.tint = NSColor.systemRed
        mainRow.addArrangedSubview(cancel)
        let done = ToolButton(symbol: "checkmark", tooltip: "完成 Enter") { [weak self] in self?.onAction?(.done) }
        done.tint = Palette.accent
        mainRow.addArrangedSubview(done)

        for t in Thickness.allCases {
            let b = ToolButton(symbol: nil, tooltip: t.title) { [weak self] in self?.setThickness(t) }
            b.dotDiameter = t.dotDiameter
            thicknessButtons.append(b)
            optionRow.addArrangedSubview(b)
        }
        optionSeparator = Separator()
        optionRow.addArrangedSubview(optionSeparator)
        for c in Palette.colors {
            let b = ToolButton(symbol: nil, tooltip: "") { [weak self] in self?.setColor(c) }
            b.swatch = c
            colorButtons.append(b)
            optionRow.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            mainRow.topAnchor.constraint(equalTo: topAnchor),
            mainRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            optionRow.topAnchor.constraint(equalTo: mainRow.bottomAnchor),
            optionRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            optionRow.heightAnchor.constraint(equalToConstant: Self.optionRowHeight),
        ])
        refreshOptionSelection()
    }

    var canUndo: Bool = false { didSet { undoButton.isEnabled = canUndo } }

    /// 当前需要的整体尺寸。选中任何工具都展开选项行（马赛克只有粗细），高度必须与 updateVisibility 一致，
    /// 否则选项行会悬在面板之外、点不到。
    var preferredSize: CGSize {
        let w = mainRow.fittingSize.width
        let h = Self.rowHeight + (selectedTool == nil ? 0 : Self.optionRowHeight)
        return CGSize(width: w, height: h)
    }

    private func toggleTool(_ tool: ToolKind) {
        selectTool(selectedTool == tool ? nil : tool)
    }

    /// 程序化选择工具（nil 为取消选择），效果等同点击工具栏按钮。
    func selectTool(_ tool: ToolKind?) {
        selectedTool = tool
        for (k, b) in toolButtons { b.isSelected = (k == selectedTool) }
        updateVisibility()
        onSelectTool?(selectedTool)
    }

    func deselectTool() {
        selectedTool = nil
        for b in toolButtons.values { b.isSelected = false }
        updateVisibility()
    }

    private func updateVisibility() {
        optionRow.isHidden = (selectedTool == nil)
        // 马赛克只关心粗细，颜色和分隔线一起藏起来
        let mosaic = (selectedTool == .mosaic)
        optionSeparator.isHidden = mosaic
        for b in colorButtons { b.isHidden = mosaic }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { preferredSize }

    private func setThickness(_ t: Thickness) {
        style.thickness = t
        refreshOptionSelection()
        onStyleChange?(style)
    }
    private func setColor(_ c: NSColor) {
        style.color = c
        refreshOptionSelection()
        onStyleChange?(style)
    }
    private func refreshOptionSelection() {
        for (i, b) in thicknessButtons.enumerated() { b.isSelected = (i == style.thickness.rawValue) }
        for (i, b) in colorButtons.enumerated() { b.isSelected = (Palette.colors[i] == style.color) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) { /* 吞掉，不传给覆盖层 */ }
    override func rightMouseDown(with event: NSEvent) {}
}

/// 工具栏里的一个按钮：SF Symbol / 粗细圆点 / 色块 三种形态。
final class ToolButton: NSView {
    var tint: NSColor = NSColor(white: 0.25, alpha: 1) { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var dotDiameter: CGFloat = 0 { didSet { needsDisplay = true } }
    var swatch: NSColor? { didSet { needsDisplay = true } }
    private let symbol: String?
    private let action: () -> Void
    private var hovered = false

    init(symbol: String?, tooltip: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        toolTip = tooltip.isEmpty ? nil : tooltip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        if isSelected || hovered {
            NSColor(white: 0, alpha: isSelected ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
        let color = isEnabled ? (isSelected && symbol != nil ? Palette.accent : tint) : tint.withAlphaComponent(0.3)
        if let swatch {
            let s = bounds.insetBy(dx: 7, dy: 7)
            swatch.setFill()
            NSBezierPath(ovalIn: s).fill()
            NSColor(white: 0.6, alpha: 1).setStroke()
            NSBezierPath(ovalIn: s).stroke()
            if isSelected {
                Palette.accent.setStroke()
                let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)); p.lineWidth = 2; p.stroke()
            }
        } else if dotDiameter > 0 {
            color.setFill()
            let d = dotDiameter
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        } else if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let tinted = img.withSymbolConfiguration(cfg)?.tinted(color) ?? img
            let size = tinted.size
            tinted.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
}

final class Separator: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 9).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.12).setFill()
        NSRect(x: bounds.midX - 0.5, y: 6, width: 1, height: bounds.height - 12).fill()
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}
