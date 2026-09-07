import AppKit
import CoreGraphics

/// 屏幕上一个可被"自动识别"的窗口，frame 为 AppKit 坐标（y 向上）。
struct LocatableWindow: Equatable {
    let frame: CGRect
    let pid: pid_t
}

/// 光标所在的最上层窗口定位。纯逻辑部分与系统调用分开，便于测试。
enum WindowLocator {
    /// 从系统取当前在屏窗口（前→后顺序），转换到 AppKit 坐标。
    static func onScreenWindows() -> [LocatableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0.01, cgBounds.width >= 10, cgBounds.height >= 10 else { return nil }
            return LocatableWindow(frame: cgToAppKit(cgBounds, primaryHeight: primaryHeight), pid: pid)
        }
    }

    /// CoreGraphics 窗口坐标（原点在主屏左上、y 向下）→ AppKit（原点在主屏左下、y 向上）
    static func cgToAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 在按前→后排序的窗口列表里找第一个包含 point 的窗口，并裁到所在屏幕。
    /// 不排除本进程：Clipper 自己的设置窗口也应能被识别；覆盖层不在列表里（列表在覆盖窗出现前取）。
    static func topmostWindow(at point: CGPoint,
                              in windows: [LocatableWindow],
                              clampTo screenFrame: CGRect) -> CGRect? {
        for w in windows where w.frame.contains(point) {
            let clipped = w.frame.intersection(screenFrame)
            if !clipped.isNull && clipped.width >= 1 && clipped.height >= 1 { return clipped }
        }
        return nil
    }
}
