import AppKit

/// 菜单栏图标与下拉菜单。
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let onCapture: () -> Void
    private let onHistory: () -> Void
    private let onSettings: () -> Void
    private let onCheckUpdates: () -> Void
    private let onQuit: () -> Void

    init(onCapture: @escaping () -> Void, onHistory: @escaping () -> Void = {}, onSettings: @escaping () -> Void,
         onCheckUpdates: @escaping () -> Void = {}, onQuit: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onHistory = onHistory
        self.onSettings = onSettings
        self.onCheckUpdates = onCheckUpdates
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            button.image = MenuBarIcon.make()
            button.toolTip = L10n.t("Cropmark 截图")
        }

        let menu = NSMenu()
        let capture = NSMenuItem(title: L10n.t("截图"), action: #selector(captureAction), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)
        historyItem = NSMenuItem(title: L10n.t("截图历史"), action: #selector(historyAction), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.t("设置…"), action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(title: L10n.t("检查更新…"), action: #selector(checkUpdatesAction), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.t("退出 Cropmark"), action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        item.menu = menu
    }

    private var historyItem: NSMenuItem!

    @objc private func captureAction() {
        // 等菜单收起再截，避免把菜单自己截进去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.onCapture() }
    }
    @objc private func historyAction() { onHistory() }
    @objc private func settingsAction() { onSettings() }
    @objc private func checkUpdatesAction() { onCheckUpdates() }
    @objc private func quitAction() { onQuit() }
}

extension StatusItemController: NSMenuDelegate {
    /// 保存数量设成 0 就是关掉了历史，菜单项跟着藏起来
    func menuNeedsUpdate(_ menu: NSMenu) {
        historyItem.isHidden = Preferences.historyLimit == 0
    }
}
