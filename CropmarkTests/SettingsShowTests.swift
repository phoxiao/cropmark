import XCTest
import AppKit
@testable import Cropmark

@MainActor
final class SettingsShowTests: XCTestCase {
    /// 走一遍菜单「设置…」的真实路径：AppDelegate 用的是无参构造，窗口必须真的显示出来。
    /// 曾经踩过：给 init(initialTab:) 加默认值后，无参调用被 NSWindowController
    /// 继承来的 init() 抢走，window 为 nil，show() 全走可选链，点菜单静默没反应。
    func testShowPutsWindowOnScreen() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window, "无参构造没建出窗口")
        controller.show()
        XCTAssertTrue(window.isVisible, "窗口没显示: frame=\(window.frame)")
        XCTAssertGreaterThan(window.frame.height, 200, "窗口高度不对: \(window.frame)")
        XCTAssertEqual(window.frame.width, SettingsView.width)
        // 不能被挪到屏幕外
        XCTAssertNotNil(window.screen, "窗口不在任何屏幕上: \(window.frame)")
    }

    /// 无参构造和显式指定分页必须落到同一条路径上
    func testDefaultInitOpensGeneralTab() throws {
        let byDefault = try XCTUnwrap(SettingsWindowController().window)
        let explicit = try XCTUnwrap(SettingsWindowController(initialTab: .general).window)
        byDefault.contentView?.layoutSubtreeIfNeeded()
        explicit.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(byDefault.title, explicit.title)
        XCTAssertEqual(byDefault.contentView?.bounds, explicit.contentView?.bounds)
    }
}
