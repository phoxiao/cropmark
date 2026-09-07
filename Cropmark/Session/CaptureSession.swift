import AppKit

/// 保证同一时间只有一个截图会话。
@MainActor
final class CaptureCoordinator {
    private var session: CaptureSession?

    func begin() {
        guard session == nil else { return }
        guard PermissionGuard.ensureAccessOrExplain() else { return }
        Task { @MainActor in
            do {
                let snapshots = try await ScreenGrabber.grabAllScreens()
                let s = CaptureSession(snapshots: snapshots) { [weak self] in self?.session = nil }
                session = s
                s.start()
            } catch {
                let alert = NSAlert()
                alert.messageText = "截图失败"
                alert.informativeText = "\(error)"
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
}

/// 一次截图：为每块屏幕建覆盖窗，收集结果，收尾。
@MainActor
final class CaptureSession {
    private let snapshots: [ScreenSnapshot]
    private var windows: [OverlayWindow] = []
    private let onFinish: () -> Void
    private var finished = false
    /// 会话开始时的在屏窗口列表，用于悬停识别。
    /// 必须在覆盖窗创建之前取：这样列表里天然没有覆盖层，也就不需要按进程排除，本应用自己的窗口照常可识别。
    let windowList: [LocatableWindow]
    /// 已有选区的那块屏幕的视图，其他屏幕进入"旁观"状态
    weak var activeView: OverlayView?
    /// 结果写入的剪贴板（测试时可替换）
    var pasteboard: NSPasteboard = .general
    private(set) var lastImage: CGImage?

    init(snapshots: [ScreenSnapshot], windowList: [LocatableWindow]? = nil, onFinish: @escaping () -> Void) {
        self.snapshots = snapshots
        self.onFinish = onFinish
        self.windowList = windowList ?? WindowLocator.onScreenWindows()
    }

    func start() {
        windows = snapshots.map { OverlayWindow(snapshot: $0, session: self) }
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

    func cancel() { teardown() }

    func complete(with image: CGImage) {
        lastImage = image
        teardown()
        Exporter.copyToPasteboard(image, to: pasteboard)
        if Preferences.playSound { Exporter.playCaptureSound() }
    }

    func save(_ image: CGImage) {
        lastImage = image
        teardown()
        Exporter.saveWithPanel(image)
    }

    private func teardown() {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        onFinish()
    }
}
