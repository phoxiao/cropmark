import Foundation
import ServiceManagement

/// 用户偏好（UserDefaults 封装）。
enum Preferences {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let playSound = "playSound"
        static let didRequestScreenCapture = "didRequestScreenCapture"
        static let detectInAppDialogs = "detectInAppDialogs"
        static let didUseDialogModifier = "didUseDialogModifier"
        static let copyAt1x = "copyAt1x"
        static let saveAt1x = "saveAt1x"
        static let clipboardIncludesFile = "clipboardIncludesFile"
        static let historyLimit = "historyLimit"
    }

    static let historyLimitRange = 0...20

    /// 截图历史保留几张，0 表示关闭。调小后由调用方让 HistoryStore 立刻删掉多出来的
    static var historyLimit: Int {
        get {
            let v = defaults.object(forKey: Key.historyLimit) as? Int ?? 5
            return min(max(v, historyLimitRange.lowerBound), historyLimitRange.upperBound)
        }
        set { defaults.set(min(max(newValue, historyLimitRange.lowerBound), historyLimitRange.upperBound), forKey: Key.historyLimit) }
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

    /// 识别应用内部的弹出对话框、面板、卡片的总闸。直接看冻结截图的像素，不需要任何额外权限。
    /// 开着也不会自动识别：截图时还要按住 ⌘ 才触发（见 OverlayView.dialogModifier）。
    static var detectInAppDialogs: Bool {
        get { defaults.object(forKey: Key.detectInAppDialogs) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.detectInAppDialogs) }
    }

    /// 用户是否已经按过一次 ⌘ 来识别对话框。按过就不再在截图覆盖层上提示这个键。
    static var didUseDialogModifier: Bool {
        get { defaults.bool(forKey: Key.didUseDialogModifier) }
        set { defaults.set(newValue, forKey: Key.didUseDialogModifier) }
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
