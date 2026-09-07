import AppKit

/// 菜单栏图标与下拉菜单。
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let onCapture: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(onCapture: @escaping () -> Void, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            button.image = MenuBarIcon.make()
            button.toolTip = "Cropmark 截图"
        }

        let menu = NSMenu()
        let capture = NSMenuItem(title: "截图", action: #selector(captureAction), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Cropmark", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func captureAction() {
        // 等菜单收起再截，避免把菜单自己截进去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.onCapture() }
    }
    @objc private func settingsAction() { onSettings() }
    @objc private func quitAction() { onQuit() }
}
