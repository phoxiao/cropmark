import XCTest
import SwiftUI
@testable import Clipper

@MainActor
final class SettingsRenderTests: XCTestCase {
    /// 设置窗口内容必须有实际高度，并离屏渲染一张图供检查
    func testSettingsHasContentAndRenders() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(content.bounds.height, 200, "settings content collapsed: \(content.bounds)")
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ClipperBuild")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("preview-5-settings.png"))
    }
}
