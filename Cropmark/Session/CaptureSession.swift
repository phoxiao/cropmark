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

    var isBusy: Bool { starting || session != nil }

    init(ensurePermission: @escaping @MainActor () -> Bool = { PermissionGuard.ensureAccessOrExplain() },
         grab: @escaping Grabber = { try await ScreenGrabber.grabAllScreens() }) {
        self.ensurePermission = ensurePermission
        self.grab = grab
    }

    func begin() {
        guard !isBusy else { return }
        // 记下用户正在用的应用，截完把焦点还回去，这样 Enter 之后直接 ⌘V 就能粘贴
        let previous = NSWorkspace.shared.frontmostApplication
        guard ensurePermission() else { return }
        starting = true
        Task { @MainActor in
            defer { starting = false }
            do {
                let snapshots = try await grab()
                let s = CaptureSession(snapshots: snapshots,
                                       returnFocus: { Self.reactivate(previous) },
                                       onFinish: { [weak self] in self?.session = nil })
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
                    alert.messageText = "截图失败"
                    alert.informativeText = message
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    /// 权限预检通过、真抓屏却被系统拒绝（比如授权后还没重启应用），要按权限问题处理。
    static func failure(for error: Error) -> Failure {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue {
            return .permission
        }
        if error is ScreenGrabError {
            return .other("没有找到可以截取的显示器，请重试。")
        }
        return .other("\(ns.localizedDescription)\n\n请重试；如果反复出现，到「设置」里检查屏幕录制权限状态。")
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
    private(set) var lastImage: CGImage?

    init(snapshots: [ScreenSnapshot],
         windowList: [LocatableWindow]? = nil,
         returnFocus: @escaping () -> Void = {},
         onFinish: @escaping () -> Void) {
        self.snapshots = snapshots
        self.onFinish = onFinish
        self.returnFocus = returnFocus
        self.windowList = windowList ?? WindowLocator.onScreenWindows()
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

    func complete(with image: CGImage, scale: CGFloat) {
        lastImage = image
        teardown()
        Exporter.copyToPasteboard(image, scale: scale, to: pasteboard)
        if Preferences.playSound { Exporter.playCaptureSound() }
        returnFocus()
    }

    func save(_ image: CGImage, scale: CGFloat) {
        lastImage = image
        teardown()
        // 先放进剪贴板：保存框取消或写入失败时，截图也不会丢
        Exporter.copyToPasteboard(image, scale: scale, to: pasteboard)
        Exporter.saveWithPanel(image, scale: scale)
        returnFocus()
    }

    private func teardown() {
        guard !finished else { return }
        finished = true
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        onFinish()
    }
}
