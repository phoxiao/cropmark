import AppKit
import SwiftUI

/// 设置页的分组。写法同 ToolKind：标题走 L10n，symbol 是 SF Symbol 名。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, output, keys, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.t("通用")
        case .output: return L10n.t("输出")
        case .keys: return L10n.t("按键")
        case .about: return L10n.t("关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .output: return "doc.on.clipboard"
        case .keys: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

/// 设置窗口顶部的分页条：图标在上、标题在下
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @State private var hovered: SettingsTab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        // 各个 SF Symbol 的固有高度不一样，不给固定高度的话
                        // VStack 各自居中，四个标题的基线会错开几个点
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18))
                            .frame(height: 22)
                        Text(tab.title).font(.caption)
                    }
                    .frame(width: 72, height: 50)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background(fill(for: tab), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tab : nil }
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                .help(tab.title)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func fill(for tab: SettingsTab) -> Color {
        if selection == tab { return Color.accentColor.opacity(0.12) }
        if hovered == tab { return Color(nsColor: .quaternaryLabelColor).opacity(0.5) }
        return .clear
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
        ([L10n.t("拖动")], L10n.t("框选区域；松手后可拉伸、移动选区")),
        ([L10n.t("单击")], L10n.t("选中光标下的窗口")),
        (["Enter", L10n.t("双击")], L10n.t("完成，复制到剪贴板")),
        (["⌘S"], L10n.t("保存为 PNG 文件")),
        (["⌘Z"], L10n.t("撤销上一步标注")),
        (["Shift", L10n.t("拖动")], L10n.t("正方形 / 正圆 / 45° 箭头")),
        ([L10n.t("右键")], L10n.t("重新框选；再按一次退出")),
        (["Esc"], L10n.t("取消")),
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
