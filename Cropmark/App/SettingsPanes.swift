import AppKit
import SwiftUI
import ServiceManagement
import KeyboardShortcuts

/// 通用：快捷键、行为、屏幕录制权限
struct GeneralPane: View {
    let hasPermission: Bool
    /// 由外壳持有：窗口重新激活时要重新读一次系统登录项状态
    @Binding var launchStatus: SMAppService.Status
    /// 快捷键改动后通知外壳重新读一次，「关于」页的介绍语要跟着变
    let onShortcutChange: () -> Void

    @State private var playSound = Preferences.playSound
    @State private var detectDialogs = Preferences.detectInAppDialogs

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { launchStatus == .enabled },
            set: { on in
                Preferences.launchAtLogin = on
                launchStatus = Preferences.launchAtLoginStatus
                // 系统要求用户手动批准时，直接带到「登录项」页面
                if on, launchStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        )
    }

    private var launchFooter: String? {
        launchStatus == .requiresApproval
            ? L10n.t("系统要求在「登录项与扩展」里手动允许 Cropmark，允许后这里会自动变为开启。")
            : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: L10n.t("快捷键"), footer: L10n.t("若其他应用也注册了同一快捷键，按下时两边都会响应，或被对方拦截而 Cropmark 收不到：在对方设置里改掉，或在这里换一个。F1–F12 可以单独作为快捷键。")) {
                SettingsRow(L10n.t("截图快捷键")) {
                    KeyboardShortcuts.Recorder(for: .capture) { _ in onShortcutChange() }
                }
            }
            SettingsSection(title: L10n.t("行为"), footer: launchFooter) {
                SettingsRow(L10n.t("截图完成后播放提示音")) {
                    Toggle("", isOn: $playSound).labelsHidden().toggleStyle(.switch)
                        .onChange(of: playSound) { _, v in Preferences.playSound = v }
                }
                Divider().padding(.leading, 14)
                SettingsRow(L10n.t("登录时自动启动")) {
                    Toggle("", isOn: launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 14)
                SettingsRow(L10n.t("自动框选应用内的对话框")) {
                    Toggle("", isOn: $detectDialogs).labelsHidden().toggleStyle(.switch)
                        .onChange(of: detectDialogs) { _, v in Preferences.detectInAppDialogs = v }
                }
            }
            SettingsSection(title: L10n.t("权限"), footer: hasPermission ? nil : L10n.t("勾选后系统会要求退出并重新打开 Cropmark，重新打开后按快捷键即可截图。")) {
                HStack(spacing: 10) {
                    Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(hasPermission ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("屏幕录制"))
                        Text(hasPermission ? L10n.t("已授权，可以截图") : L10n.t("尚未授权，按快捷键不会有反应"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !hasPermission {
                        Button(L10n.t("打开系统设置")) { PermissionGuard.openSystemSettings() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}

/// 输出：Retina 缩放、剪贴板附带文件
struct OutputPane: View {
    @State private var copyAt1x = Preferences.copyAt1x
    @State private var saveAt1x = Preferences.saveAt1x
    @State private var clipboardIncludesFile = Preferences.clipboardIncludesFile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: L10n.t("缩放"), footer: L10n.t("Retina 屏幕的截图像素是显示尺寸的两倍，缩小到 1x 后贴进聊天、文档不会变大，体积也小得多。")) {
                SettingsRow(L10n.t("复制到剪贴板时缩小到 1x")) {
                    Toggle("", isOn: $copyAt1x).labelsHidden().toggleStyle(.switch)
                        .onChange(of: copyAt1x) { _, v in Preferences.copyAt1x = v }
                }
                Divider().padding(.leading, 14)
                SettingsRow(L10n.t("保存文件时缩小到 1x")) {
                    Toggle("", isOn: $saveAt1x).labelsHidden().toggleStyle(.switch)
                        .onChange(of: saveAt1x) { _, v in Preferences.saveAt1x = v }
                }
            }
            SettingsSection(title: L10n.t("剪贴板"), footer: L10n.t("附带文件后，粘贴到 Finder、Slack、终端这类只认文件的地方也能用。")) {
                SettingsRow(L10n.t("剪贴板同时附带 PNG 文件")) {
                    Toggle("", isOn: $clipboardIncludesFile).labelsHidden().toggleStyle(.switch)
                        .onChange(of: clipboardIncludesFile) { _, v in Preferences.clipboardIncludesFile = v }
                }
            }
        }
    }
}

/// 按键：截图界面的按键说明
struct KeysPane: View {
    var body: some View {
        SettingsSection(title: L10n.t("截图时的按键")) {
            KeyTable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

/// 关于：图标与版本、自动更新、链接
struct AboutPane: View {
    let shortcutText: String

    @State private var autoUpdate = Updates.automaticallyChecks

    static let repoURL = "https://github.com/phoxiao/cropmark"

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SettingsSection(title: L10n.t("更新"), footer: L10n.t("每天检查一次 GitHub 上有没有新版本，只请求版本清单，不发送任何数据。也可以随时从菜单栏「检查更新…」手动检查。")) {
                SettingsRow(L10n.t("自动检查更新")) {
                    Toggle("", isOn: $autoUpdate).labelsHidden().toggleStyle(.switch)
                        .disabled(!Updates.isAvailable)
                        .onChange(of: autoUpdate) { _, v in Updates.automaticallyChecks = v }
                }
                Divider().padding(.leading, 14)
                HStack {
                    Text(L10n.t("上次检查")).foregroundStyle(.secondary)
                    Spacer()
                    Text(Updates.lastCheckDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? L10n.t("从未"))
                        .foregroundStyle(.secondary)
                    Button(L10n.t("立即检查")) { Updates.checkForUpdates() }.disabled(!Updates.isAvailable)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            SettingsSection(title: L10n.t("链接")) {
                LinkRow(title: L10n.t("项目主页"), detail: "github.com/phoxiao/cropmark", url: Self.repoURL)
                Divider().padding(.leading, 14)
                LinkRow(title: L10n.t("开源许可"), detail: "MIT License", url: Self.repoURL + "/blob/main/LICENSE")
                Divider().padding(.leading, 14)
                LinkRow(title: L10n.t("第三方许可"), detail: "KeyboardShortcuts, Sparkle (MIT)", url: Self.repoURL + "/blob/main/THIRD_PARTY_LICENSES.md")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cropmark").font(.title2.weight(.semibold))
                Text(L10n.t("轻量截图工具，随时按 %@ 截图、标注、复制", shortcutText))
                    .font(.callout).foregroundStyle(.secondary)
                Text(L10n.t("版本 %@", Self.version))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 2)
    }
}
