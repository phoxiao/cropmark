import AppKit
import CoreGraphics

/// 「屏幕录制」权限检测与引导。
enum PermissionGuard {
    static var hasScreenCaptureAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// 触发系统授权弹窗（只在首次有效，之后需用户去系统设置手动开）。
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// 未授权时引导用户，返回是否已授权。
    /// 第一次只交给系统弹授权框，不再叠一个自己的提示；之后系统不会再弹，才由我们来解释。
    @MainActor
    static func ensureAccessOrExplain() -> Bool {
        if hasScreenCaptureAccess { return true }
        if !Preferences.didRequestScreenCapture {
            Preferences.didRequestScreenCapture = true
            return requestScreenCaptureAccess()
        }
        explain()
        return false
    }

    /// 弹出「需要屏幕录制权限」的说明框，可跳到系统设置。
    @MainActor
    static func explain() {
        let alert = NSAlert()
        alert.messageText = L10n.t("Cropmark 需要「屏幕录制」权限")
        alert.informativeText = L10n.t("请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 Cropmark。系统会要求退出并重新打开 Cropmark，重新打开后再按快捷键。")
        alert.addButton(withTitle: L10n.t("打开系统设置"))
        alert.addButton(withTitle: L10n.t("稍后"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSystemSettings() }
    }
}
