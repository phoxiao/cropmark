import AppKit
import ScreenCaptureKit

/// 保证同一时间只有一个截图会话。
@MainActor
final class CaptureCoordinator {
    typealias Grabber = @MainActor () async throws -> [ScreenSnapshot]

    /// 抓屏失败的分类：权限问题走权限引导，其他给一句人话
    enum Failure: Equatable {
        case permission
        case other(String)
    }

    private let ensurePermission: @MainActor () -> Bool
    private let grab: Grabber
    private var session: CaptureSession?
    /// 抓屏进行中（还没有 session 对象）。这段时间再按快捷键必须忽略，
    /// 否则会开出第二个会话，第一个会话的覆盖窗会失去 session 变成关不掉的遮罩。
    private var starting = false
    private let history: HistoryStore
    /// 历史快捷键的显示文字，放进覆盖层按钮的提示里
    private let historyShortcut: () -> String?
    private var panel: HistoryPanelController?

    var isBusy: Bool { starting || session != nil }
    var isEditingHistory: Bool { session?.editContext != nil }
    var isHistoryPanelVisible: Bool { panel?.isVisible ?? false }
    var historyPanelForTesting: HistoryPanelController? { panel }
    var sessionForTesting: CaptureSession? { session }

    init(ensurePermission: @escaping @MainActor () -> Bool = { PermissionGuard.ensureAccessOrExplain() },
         grab: @escaping Grabber = { try await ScreenGrabber.grabAllScreens() },
         history: HistoryStore? = nil,
         historyShortcut: @escaping () -> String? = { nil }) {
        self.ensurePermission = ensurePermission
        self.grab = grab
        self.history = history ?? .shared
        self.historyShortcut = historyShortcut
    }

    func begin() {
        // 历史面板开着时按截图键：收起面板去截图，焦点最后还给打开面板之前的那个应用
        var previous = NSWorkspace.shared.frontmostApplication
        if let p = panel {
            previous = panelPrevious
            panel = nil
            p.close(notify: false)
        }
        guard !isBusy else { return }
        // 记下用户正在用的应用，截完把焦点还回去，这样 Enter 之后直接 ⌘V 就能粘贴
        guard ensurePermission() else { return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do {
                let snapshots = try await grab()
                let s = CaptureSession(snapshots: snapshots,
                                       returnFocus: { Self.reactivate(previous) },
                                       onFinish: { [weak self] in self?.session = nil })
                s.history = history
                if history.isEnabled {
                    s.onOpenHistory = { [weak self] in self?.showHistory(returnTo: previous) }
                    s.historyTooltip = historyShortcut().map { L10n.t("截图历史 %@", $0) } ?? L10n.t("截图历史")
                }
                session = s
                s.start()
            } catch is CancellationError {
                // 主动取消，不用打扰用户
            } catch {
                switch Self.failure(for: error) {
                case .permission:
                    PermissionGuard.explain()
                case .other(let message):
                    let alert = NSAlert()
                    alert.messageText = L10n.t("截图失败")
                    alert.informativeText = message
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    // MARK: 截图历史

    /// 打开面板之前在用的应用。面板被动关掉（Esc、点了别处）或复制之后，焦点还给它
    private var panelPrevious: NSRunningApplication?

    /// 历史快捷键 / 菜单项。截图进行中等同于点右上角按钮；重新编辑中忽略，免得丢掉改了一半的标注
    func showHistory() {
        guard history.isEnabled, !starting else { return }
        if let s = session {
            if s.editContext == nil { s.openHistory() }
            return
        }
        if let panel, panel.isVisible { panel.bringToFront(); return }
        showHistory(returnTo: NSWorkspace.shared.frontmostApplication)
    }

    private func showHistory(returnTo previous: NSRunningApplication?) {
        guard history.isEnabled, !isBusy else { return }
        panel?.close(notify: false)
        panelPrevious = previous
        let p = HistoryPanelController(store: history)
        p.onClose = { [weak self] in
            guard let self else { return }
            self.panel = nil
            Self.reactivate(previous)
        }
        p.onAction = { [weak self] action, entry in
            guard let self else { return }
            self.panel = nil
            self.perform(action, entry, returnTo: previous)
        }
        panel = p
        p.show()
    }

    private func perform(_ action: HistoryAction, _ entry: HistoryEntry, returnTo previous: NSRunningApplication?) {
        switch action {
        case .copy:
            guard let img = history.final(for: entry) else { NSSound.beep(); return }
            let opts = ExportOptions.current
            let out = Exporter.output(img, scale: entry.scale, at1x: opts.copyAt1x)
            Exporter.copyToPasteboard(out.image, scale: out.scale, includeFile: opts.clipboardIncludesFile)
            if Preferences.playSound { Exporter.playCaptureSound() }
            Self.reactivate(previous)
        case .save:
            guard let img = history.final(for: entry) else { NSSound.beep(); return }
            let out = Exporter.output(img, scale: entry.scale, at1x: ExportOptions.current.saveAt1x)
            Exporter.saveWithPanel(out.image, scale: out.scale)
            Self.reactivate(previous)
        case .edit:
            edit(entry, returnTo: previous)
        case .delete:
            history.delete(entry.id)
        }
    }

    /// 在光标所在的屏幕上重新编辑一条历史截图
    func edit(_ entry: HistoryEntry, returnTo previous: NSRunningApplication? = nil) {
        guard !isBusy, let base = history.base(for: entry) else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let ctx = HistoryEditContext(entry: entry, base: base, screen: screen) else { return }
        let s = CaptureSession(snapshots: [ctx.snapshot], windowList: [], elementDetection: .off, editContext: ctx,
                               returnFocus: { Self.reactivate(previous) },
                               onFinish: { [weak self] in self?.session = nil })
        s.history = history
        session = s
        s.start()
    }

    /// 权限预检通过、真抓屏却被系统拒绝（比如授权后还没重启应用），要按权限问题处理。
    static func failure(for error: Error) -> Failure {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue {
            return .permission
        }
        if error is ScreenGrabError {
            return .other(L10n.t("没有找到可以截取的显示器，请重试。"))
        }
        return .other(L10n.t("%@\n\n请重试；如果反复出现，到「设置」里检查屏幕录制权限状态。", ns.localizedDescription))
    }

    private static func reactivate(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier, !app.isTerminated else { return }
        app.activate(from: .current, options: [])
    }
}

/// 一次截图：为每块屏幕建覆盖窗，收集结果，收尾。
@MainActor
final class CaptureSession {
    private let snapshots: [ScreenSnapshot]
    private(set) var windows: [OverlayWindow] = []
    private let onFinish: () -> Void
    private let returnFocus: () -> Void
    private var finished = false
    /// 会话开始时的在屏窗口列表，用于悬停识别。
    /// 必须在覆盖窗创建之前取：这样列表里天然没有覆盖层，也就不需要按进程排除，本应用自己的窗口照常可识别。
    let windowList: [LocatableWindow]
    /// 已有选区的那块屏幕的视图，其他屏幕进入"旁观"状态
    weak var activeView: OverlayView?
    /// 结果写入的剪贴板（测试时可替换）
    var pasteboard: NSPasteboard = .general
    /// 导出选项（缩放、附带文件），会话开始时从偏好读一次，测试可覆盖
    var exportOptions: ExportOptions = .current
    private(set) var lastImage: CGImage?
    /// 块级识别（应用内的弹出对话框）的来源。真正的 resolver 由每块屏幕的覆盖层各建一个，
    /// 因为识别要看那块屏幕自己的冻结截图。
    let elementDetection: ElementDetection
    /// 非 nil 表示这是一次重新编辑历史截图，而不是新截图
    let editContext: HistoryEditContext?
    /// 完成的截图交给它入库；nil 表示不记历史（测试默认如此，免得写进真实目录）
    var history: HistoryStore?
    /// 覆盖层右上角的历史按钮点下去要做的事。nil 表示不显示这个按钮
    var onOpenHistory: (() -> Void)?
    var historyTooltip = L10n.t("截图历史")

    /// 块级识别从哪来。开关只在会话开始时读一次就定了。
    enum ElementDetection {
        /// 按偏好开关决定，识别对象是那块屏幕的冻结截图
        case automatic
        /// 显式关掉
        case off
        /// 注入实现，单测用。同步执行，好让「合成事件 + 立即断言」的写法继续成立。
        case injected(ElementLocating)

        @MainActor func resolver(for snapshot: ScreenSnapshot) -> HoverResolver? {
            switch self {
            case .off:
                return nil
            case .injected(let locator):
                return HoverResolver(locator: locator, queue: nil)
            case .automatic:
                guard Preferences.detectInAppDialogs else { return nil }
                return HoverResolver(locator: BlockLocator(image: snapshot.image,
                                                           screenFrame: snapshot.frame,
                                                           scale: snapshot.scale))
            }
        }
    }

    init(snapshots: [ScreenSnapshot],
         windowList: [LocatableWindow]? = nil,
         elementDetection: ElementDetection = .automatic,
         editContext: HistoryEditContext? = nil,
         returnFocus: @escaping () -> Void = {},
         onFinish: @escaping () -> Void) {
        self.snapshots = snapshots
        self.onFinish = onFinish
        self.returnFocus = returnFocus
        self.windowList = windowList ?? WindowLocator.onScreenWindows()
        self.elementDetection = elementDetection
        self.editContext = editContext
    }

    /// 光标所在的最上层窗口（裁到该屏），带 pid 供元素级识别使用。
    func windowHit(at point: CGPoint, clampTo screenFrame: CGRect) -> LocatableWindow? {
        WindowLocator.topmostHit(at: point, in: windowList, clampTo: screenFrame)
    }

    /// 创建（不显示）每块屏幕的覆盖窗。测试用它拿到窗口而不真的盖住屏幕。
    @discardableResult
    func makeWindows() -> [OverlayWindow] {
        if windows.isEmpty { windows = snapshots.map { OverlayWindow(snapshot: $0, session: self) } }
        return windows
    }

    func start() {
        makeWindows()
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for w in windows { w.orderFrontRegardless() }
        let under = windows.first { $0.snapshot.frame.contains(mouse) } ?? windows.first
        under?.makeKeyAndOrderFront(nil)
    }

    func selectionDidBegin(on view: OverlayView) {
        activeView = view
        for w in windows where w.overlayView !== view { w.overlayView.becomeBystander() }
    }

    func selectionDidClear() {
        activeView = nil
        for w in windows { w.overlayView.leaveBystander() }
    }

    /// 在旁观屏幕上右键：把别的屏幕上的选区清掉，好在这块屏幕重新框选。
    func clearSelection() {
        activeView?.resetSelection()
    }

    func cancel() {
        teardown()
        returnFocus()
    }

    /// 关掉覆盖层去打开历史面板。焦点不还给原来的应用：面板马上要拿走它
    func openHistory() {
        guard let onOpenHistory else { return }
        teardown()
        onOpenHistory()
    }

    func complete(with image: CGImage, scale: CGFloat, archive: HistoryArchive? = nil) {
        lastImage = image
        teardown()
        copy(image, scale: scale)
        if Preferences.playSound { Exporter.playCaptureSound() }
        returnFocus()
        // 入库放在焦点归还之后：用户此刻多半正要 ⌘V，别让这点活挡在前面
        if let archive { history?.record(archive, final: image) }
    }

    func save(_ image: CGImage, scale: CGFloat, archive: HistoryArchive? = nil) {
        lastImage = image
        teardown()
        // 先放进剪贴板：保存框取消或写入失败时，截图也不会丢
        copy(image, scale: scale)
        if let archive { history?.record(archive, final: image) }
        let file = Exporter.output(image, scale: scale, at1x: exportOptions.saveAt1x)
        Exporter.saveWithPanel(file.image, scale: file.scale)
        returnFocus()
    }

    private func copy(_ image: CGImage, scale: CGFloat) {
        let out = Exporter.output(image, scale: scale, at1x: exportOptions.copyAt1x)
        Exporter.copyToPasteboard(out.image, scale: out.scale,
                                  includeFile: exportOptions.clipboardIncludesFile, to: pasteboard)
    }

    private func teardown() {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        onFinish()
    }
}
