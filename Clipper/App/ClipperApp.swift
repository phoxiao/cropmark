import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 截图快捷键，默认与微信一致：⌃⌘A
    static let capture = Self("capture", default: .init(.a, modifiers: [.control, .command]))
}

@main
enum ClipperMain {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(
            onCapture: { [weak self] in self?.coordinator.begin() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        KeyboardShortcuts.onKeyDown(for: .capture) { [weak self] in
            self?.coordinator.begin()
        }
        if !PermissionGuard.hasScreenCaptureAccess {
            PermissionGuard.requestScreenCaptureAccess()
        }
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
