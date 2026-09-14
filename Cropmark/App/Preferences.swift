import Foundation
import ServiceManagement

/// 用户偏好（UserDefaults 封装）。
enum Preferences {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let playSound = "playSound"
        static let didRequestScreenCapture = "didRequestScreenCapture"
        static let detectInAppDialogs = "detectInAppDialogs"
        static let copyAt1x = "copyAt1x"
        static let saveAt1x = "saveAt1x"
        static let clipboardIncludesFile = "clipboardIncludesFile"
    }

    static var playSound: Bool {
        get { defaults.object(forKey: Key.playSound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSound) }
    }

    /// 复制到剪贴板时把 Retina 截图缩小到屏幕显示尺寸（像素减半）
    static var copyAt1x: Bool {
        get { defaults.bool(forKey: Key.copyAt1x) }
        set { defaults.set(newValue, forKey: Key.copyAt1x) }
    }

    /// 保存文件时把 Retina 截图缩小到屏幕显示尺寸
    static var saveAt1x: Bool {
        get { defaults.bool(forKey: Key.saveAt1x) }
        set { defaults.set(newValue, forKey: Key.saveAt1x) }
    }

    /// 剪贴板里除了图片再放一个 PNG 文件引用，Finder / Slack / 终端这类只认文件的地方也能粘贴
    static var clipboardIncludesFile: Bool {
        get { defaults.object(forKey: Key.clipboardIncludesFile) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.clipboardIncludesFile) }
    }

    /// 是否已经向系统申请过一次屏幕录制权限（系统授权框只会弹这一次）
    static var didRequestScreenCapture: Bool {
        get { defaults.bool(forKey: Key.didRequestScreenCapture) }
        set { defaults.set(newValue, forKey: Key.didRequestScreenCapture) }
    }

    /// 悬停时识别应用内部的弹出对话框、面板、卡片。直接看冻结截图的像素，不需要任何额外权限。
    static var detectInAppDialogs: Bool {
        get { defaults.object(forKey: Key.detectInAppDialogs) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.detectInAppDialogs) }
    }

    /// 登录项的实际状态：enabled / notRegistered / requiresApproval / notFound
    static var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }

    /// 开机自启，直接读写系统登录项状态。
    static var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launchAtLogin toggle failed: \(error)")
            }
        }
    }
}
