import AppKit
import Sparkle

/// Sparkle 自动更新的薄封装：AppDelegate 启动时创建，菜单和设置页通过这里访问。
/// 测试宿主不创建（controller 为 nil），设置页里对应开关显示为不可用。
@MainActor
enum Updates {
    private(set) static var controller: SPUStandardUpdaterController?

    static func start() {
        guard controller == nil else { return }
        // startingUpdater: true 会按 Info.plist 的 SUScheduledCheckInterval 定时检查；
        // 第一次由 Sparkle 自己弹窗征求「是否自动检查」，用户没同意前不会联网。
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static var isAvailable: Bool { controller != nil }

    static func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    static var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }
}
