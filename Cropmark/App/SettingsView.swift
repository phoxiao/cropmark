import AppKit
import SwiftUI
import ServiceManagement
import KeyboardShortcuts

struct SettingsView: View {
    static let width: CGFloat = 480

    // 跨分页、或需要在窗口重新激活时被外部刷新的，才留在这一层；
    // 只有本页读写的（提示音、三个输出开关、自动更新）由各自的 pane 自持。
    @State private var selection: SettingsTab
    @State private var shortcutText = SettingsView.shortcutDescription
    @State private var hasPermission = PermissionGuard.hasScreenCaptureAccess
    @State private var launchStatus = Preferences.launchAtLoginStatus

    /// 内容高度随分页变，变了要让窗口重新贴合；由 SettingsWindowController 注入
    private let onLayoutChange: () -> Void

    /// initialTab 只给测试用，好逐个分页离屏渲染
    init(initialTab: SettingsTab = .general, onLayoutChange: @escaping () -> Void = {}) {
        _selection = State(initialValue: initialTab)
        self.onLayoutChange = onLayoutChange
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
            Divider()
            pane(selection)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selection) { _, _ in onLayoutChange() }
        .onAppear { refreshSystemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 用户可能刚从系统设置回来：权限和登录项状态都重新读一次
            refreshSystemState()
        }
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralPane(hasPermission: hasPermission,
                        launchStatus: $launchStatus,
                        onShortcutChange: { shortcutText = Self.shortcutDescription })
        case .output: OutputPane()
        case .keys: KeysPane()
        case .about: AboutPane(shortcutText: shortcutText)
        }
    }

    /// 权限和登录项的脚注会出现/消失，高度跟着变，所以刷新完要让窗口重新贴合
    private func refreshSystemState() {
        hasPermission = PermissionGuard.hasScreenCaptureAccess
        launchStatus = Preferences.launchAtLoginStatus
        onLayoutChange()
    }

    static var shortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .capture)?.description ?? L10n.t("未设置")
    }
}
