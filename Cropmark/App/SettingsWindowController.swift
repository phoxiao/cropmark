import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private var hasPositioned = false

    /// 默认打开「通用」页。这个 init() 必须显式写出来，不能靠 initialTab 的默认值：
    /// 无参的 SettingsWindowController() 会被 NSWindowController 继承来的 init() 抢走
    /// （Swift 重载决议里真正的无参 init 优先于带默认参数的），拿到一个 window 为 nil
    /// 的空壳，show() 里全是可选链，点「设置…」会静默没反应。
    convenience init() {
        self.init(initialTab: .general)
    }

    convenience init(initialTab: SettingsTab) {
        // rootView 的回调要引用 window，window 又要先有 hosting：先建一个没有回调的
        // rootView 把 window 建出来，再把带回调的换上去。此时还没显示，@State 尚未装载。
        let hosting = NSHostingController(rootView: SettingsView(initialTab: initialTab))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.t("Cropmark 设置")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        hosting.rootView = SettingsView(initialTab: initialTab) { [weak window] in
            // 回调发生在 SwiftUI 更新中途，同步 layout 会递归，推到下一轮
            DispatchQueue.main.async { window?.fitToContentHeight() }
        }
        window.fitToContentHeight()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        // 只在第一次打开时居中，之后尊重用户拖到的位置
        if !hasPositioned { window?.center(); hasPositioned = true }
        window?.makeKeyAndOrderFront(nil)
    }
}

private extension NSWindow {
    /// 贴合内容的自然高度。顶边钉住不动——setContentSize 默认保留左下角，
    /// 直接用会让窗口往下长、标题栏跟着上下跳。
    ///
    /// 没走 NSHostingController.sizingOptions = [.preferredContentSize]（那样只要一行）：
    /// 它底下也是 setContentSize，同样钉左下角，标题栏照跳；而且切分页这件事没法在
    /// 测试里驱动（AppKit 侧改不了 SwiftUI 的 @State），只能靠肉眼发现。
    /// 这里显式钉顶边，正确性由代码结构保证，不用赌。
    func fitToContentHeight() {
        guard let view = contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size.height > 0 else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        setContentSize(size)
        setFrameTopLeftPoint(topLeft)
    }
}
