import XCTest
import SwiftUI
@testable import Cropmark

@MainActor
final class SettingsRenderTests: XCTestCase {
    /// 设置窗口内容必须有实际高度，并离屏渲染一张图供检查
    func testSettingsHasContentAndRenders() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        // 既不能塌成一条，也不该留大片空白
        XCTAssertGreaterThan(content.bounds.height, 380, "settings content collapsed: \(content.bounds)")
        XCTAssertLessThan(content.bounds.height, 1400, "settings content too tall: \(content.bounds)")
        XCTAssertEqual(content.bounds.width, SettingsView.width)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/CropmarkBuild")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("preview-5-settings.png"))
    }
}
