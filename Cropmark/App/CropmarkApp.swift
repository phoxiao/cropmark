import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 截图快捷键，默认与微信一致：⌃⌘A
    static let capture = Self("capture", default: .init(.a, modifiers: [.control, .command]))
}

@main
enum CropmarkMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController?
    private let coordinator = CaptureCoordinator()

    /// 单元测试把本应用当宿主拉起时为 true：不注册快捷键、不建菜单栏、不碰权限
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        statusItem = StatusItemController(
            onCapture: { [weak self] in self?.coordinator.begin() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        KeyboardShortcuts.onKeyDown(for: .capture) { [weak self] in
            self?.coordinator.begin()
        }
        // 权限不在启动时申请：任何一份未授权的构建（比如测试宿主）一启动就会弹系统授权框，
        // 用户按快捷键触发截图时再由 PermissionGuard.ensureAccessOrExplain 申请。
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }
}
