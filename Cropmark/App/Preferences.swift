import Foundation
import ServiceManagement

/// 用户偏好（UserDefaults 封装）。
enum Preferences {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let playSound = "playSound"
        static let didRequestScreenCapture = "didRequestScreenCapture"
    }

    static var playSound: Bool {
        get { defaults.object(forKey: Key.playSound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSound) }
    }

    /// 是否已经向系统申请过一次屏幕录制权限（系统授权框只会弹这一次）
    static var didRequestScreenCapture: Bool {
        get { defaults.bool(forKey: Key.didRequestScreenCapture) }
        set { defaults.set(newValue, forKey: Key.didRequestScreenCapture) }
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
