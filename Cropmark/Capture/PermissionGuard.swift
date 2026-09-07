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

    /// 未授权时弹提示，返回是否已授权。
    @MainActor
    static func ensureAccessOrExplain() -> Bool {
        if hasScreenCaptureAccess { return true }
        requestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "Cropmark 需要「屏幕录制」权限"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 Cropmark，然后重新按快捷键截图。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSystemSettings() }
        return false
    }
}
