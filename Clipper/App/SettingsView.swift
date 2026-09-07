import AppKit
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var playSound = Preferences.playSound
    @State private var launchAtLogin = Preferences.launchAtLogin
    @State private var hasPermission = PermissionGuard.hasScreenCaptureAccess

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("截图快捷键", name: .capture)
                Toggle("截图完成后播放提示音", isOn: $playSound)
                    .onChange(of: playSound) { _, v in Preferences.playSound = v }
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        Preferences.launchAtLogin = v
                        launchAtLogin = Preferences.launchAtLogin
                    }
            }
            Section {
                HStack {
                    Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hasPermission ? .green : .orange)
                    Text(hasPermission ? "已获得「屏幕录制」权限" : "尚未授予「屏幕录制」权限，无法截图")
                    Spacer()
                    if !hasPermission {
                        Button("打开系统设置") { PermissionGuard.openSystemSettings() }
                    }
                }
            }
            Section {
                Text("在截图界面：拖动选区，Enter 或双击完成并复制到剪贴板，Esc 取消，⌘Z 撤销。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = PermissionGuard.hasScreenCaptureAccess
        }
    }
}

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.preferredContentSize = NSSize(width: 460, height: 300)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clipper 设置"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 300))
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
