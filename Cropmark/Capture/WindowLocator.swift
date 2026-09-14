import AppKit
import CoreGraphics

/// 屏幕上一个可被"自动识别"的窗口，frame 为 AppKit 坐标（y 向上）。
struct LocatableWindow: Equatable {
    let frame: CGRect
    let pid: pid_t
}

/// 光标所在的最上层窗口定位。纯逻辑部分与系统调用分开，便于测试。
enum WindowLocator {
    /// 允许被自动识别的窗口层级。**必须是白名单**：黑名单漏一个就会出事——
    /// Dock（20）的窗口铺满整块屏幕并排在所有应用之前，放进来的话每次悬停都只会选中它。
    /// 收进来的是真正「像窗口」的东西：普通窗口和 sheet（0）、浮动面板与撕下的菜单（3）、
    /// 模态面板（8）、工具面板（19）、右键菜单与部分 popover（101）。
    /// 刻意在外：Dock（20）、菜单栏（24）、状态栏（25）、覆盖层（102）、
    /// 工具提示（200）、拖拽影像（500）、光标（2147483630）、桌面小组件（负数层）。
    static let acceptedLayers: Set<Int> = Set(
        [CGWindowLevelKey.normalWindow, .floatingWindow, .modalPanelWindow, .utilityWindow, .popUpMenuWindow]
            .map { Int(CGWindowLevelForKey($0)) })

    /// 从系统取当前在屏窗口（前→后顺序），转换到 AppKit 坐标。
    static func onScreenWindows() -> [LocatableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { locatable(from: $0, primaryHeight: primaryHeight) }
    }

    /// 单条窗口信息 → 可识别窗口，不合格返回 nil。独立出来是为了能直接喂假数据做单测。
    static func locatable(from info: [String: Any], primaryHeight: CGFloat) -> LocatableWindow? {
        guard let layer = info[kCGWindowLayer as String] as? Int, acceptedLayers.contains(layer),
              info[kCGWindowIsOnscreen as String] as? Bool ?? true,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
        guard alpha > 0.01, cgBounds.width >= 10, cgBounds.height >= 10 else { return nil }
        return LocatableWindow(frame: cgToAppKit(cgBounds, primaryHeight: primaryHeight), pid: pid)
    }

    /// CoreGraphics 窗口坐标（原点在主屏左上、y 向下）→ AppKit（原点在主屏左下、y 向上）
    static func cgToAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 在按前→后排序的窗口列表里找第一个包含 point 的窗口，并裁到所在屏幕。
    /// 不排除本进程：Cropmark 自己的设置窗口也应能被识别；覆盖层不在列表里（列表在覆盖窗出现前取）。
    static func topmostWindow(at point: CGPoint,
                              in windows: [LocatableWindow],
                              clampTo screenFrame: CGRect) -> CGRect? {
        topmostHit(at: point, in: windows, clampTo: screenFrame)?.frame
    }

    /// 同 topmostWindow，但连 pid 一起带出来。返回的 frame 是裁剪后的，pid 是原窗口的。
    static func topmostHit(at point: CGPoint,
                           in windows: [LocatableWindow],
                           clampTo screenFrame: CGRect) -> LocatableWindow? {
        for w in windows where w.frame.contains(point) {
            let clipped = w.frame.intersection(screenFrame)
            if !clipped.isNull && clipped.width >= 1 && clipped.height >= 1 {
                return LocatableWindow(frame: clipped, pid: w.pid)
            }
        }
        return nil
    }
}
