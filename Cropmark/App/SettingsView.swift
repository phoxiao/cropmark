import AppKit
import SwiftUI
import ServiceManagement
import KeyboardShortcuts

struct SettingsView: View {
    @State private var playSound = Preferences.playSound
    @State private var launchStatus = Preferences.launchAtLoginStatus
    @State private var hasPermission = PermissionGuard.hasScreenCaptureAccess
    @State private var shortcutText = SettingsView.shortcutDescription

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
            ? "系统要求在「登录项与扩展」里手动允许 Cropmark，允许后这里会自动变为开启。"
            : nil
    }

    static let width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SettingsSection(title: "快捷键", footer: "若其他应用占用了同一快捷键，二者会互相抢键：在对方设置里改掉，或在这里换一个。") {
                SettingsRow("截图快捷键") {
                    KeyboardShortcuts.Recorder(for: .capture) { _ in shortcutText = Self.shortcutDescription }
                }
            }
            SettingsSection(title: "行为", footer: launchFooter) {
                SettingsRow("截图完成后播放提示音") {
                    Toggle("", isOn: $playSound).labelsHidden().toggleStyle(.switch)
                        .onChange(of: playSound) { _, v in Preferences.playSound = v }
                }
                Divider().padding(.leading, 14)
                SettingsRow("登录时自动启动") {
                    Toggle("", isOn: launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsSection(title: "权限", footer: hasPermission ? nil : "勾选后系统会要求退出并重新打开 Cropmark，重新打开后按快捷键即可截图。") {
                HStack(spacing: 10) {
                    Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(hasPermission ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("屏幕录制")
                        Text(hasPermission ? "已授权，可以截图" : "尚未授权，按快捷键不会有反应")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !hasPermission {
                        Button("打开系统设置") { PermissionGuard.openSystemSettings() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            SettingsSection(title: "截图时的按键") {
                KeyTable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            SettingsSection(title: "关于") {
                LinkRow(title: "项目主页", detail: "github.com/phoxiao/cropmark", url: Self.repoURL)
                Divider().padding(.leading, 14)
                LinkRow(title: "开源许可", detail: "MIT License", url: Self.repoURL + "/blob/main/LICENSE")
                Divider().padding(.leading, 14)
                LinkRow(title: "第三方许可", detail: "KeyboardShortcuts (MIT)", url: Self.repoURL + "/blob/main/THIRD_PARTY_LICENSES.md")
            }
        }
        .padding(20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { hasPermission = PermissionGuard.hasScreenCaptureAccess }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户可能刚从系统设置回来：权限和登录项状态都重新读一次
            hasPermission = PermissionGuard.hasScreenCaptureAccess
            launchStatus = Preferences.launchAtLoginStatus
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Cropmark").font(.title2.weight(.semibold))
                Text("轻量截图工具，随时按 \(shortcutText) 截图、标注、复制")
                    .font(.callout).foregroundStyle(.secondary)
                Text("版本 \(Self.version)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 2)
    }

    static var shortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .capture)?.description ?? "未设置"
    }

    static let repoURL = "https://github.com/phoxiao/cropmark"

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// 一组设置：小标题 + 圆角卡片 + 可选脚注
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            if let footer {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}

/// 标签在左、控件在右的一行
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// 可点击打开网页的一行
struct LinkRow: View {
    let title: String
    let detail: String
    let url: String
    var body: some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 截图界面的按键说明表
struct KeyTable: View {
    private let rows: [(keys: [String], action: String)] = [
        (["拖动"], "框选区域；松手后可拉伸、移动选区"),
        (["单击"], "选中光标下的窗口"),
        (["Enter", "双击"], "完成，复制到剪贴板"),
        (["⌘S"], "保存为 PNG 文件"),
        (["⌘Z"], "撤销上一步标注"),
        (["Shift", "拖动"], "正方形 / 正圆 / 45° 箭头"),
        (["右键"], "重新框选；再按一次退出"),
        (["Esc"], "取消"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    HStack(spacing: 4) {
                        ForEach(row.keys, id: \.self) { KeyCap(text: $0) }
                    }
                    .gridColumnAlignment(.trailing)
                    Text(row.action).font(.callout)
                }
            }
        }
    }
}

/// 键帽样式
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

final class SettingsWindowController: NSWindowController {
    private var hasPositioned = false

    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Cropmark 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        hosting.view.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.view.fittingSize)
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        // 只在第一次打开时居中，之后尊重用户拖到的位置
        if !hasPositioned { window?.center(); hasPositioned = true }
        window?.makeKeyAndOrderFront(nil)
    }
}
