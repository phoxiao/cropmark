import Foundation
import ServiceManagement

/// 用户偏好（UserDefaults 封装）。
enum Preferences {
    private static let defaults = UserDefaults.standard
    private enum Key {
        static let playSound = "playSound"
    }

    static var playSound: Bool {
        get { defaults.object(forKey: Key.playSound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSound) }
    }

    /// 开机自启，直接读写系统登录项状态。
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
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
