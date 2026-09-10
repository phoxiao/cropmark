import XCTest
import AppKit
@testable import Cropmark

/// 设置窗口每个分页的高度区间。拆分前是单页 1269pt；
/// 上下界要同时容得下中英文两种文案的折行差异，所以留得比实测宽。
enum SettingsLayout {
    static let minHeight: CGFloat = 240
    static let maxHeight: CGFloat = 620
}

extension XCTestCase {
    /// 把视图离屏渲染成 PNG 落到构建缓存目录，供人工检查排版。
    /// 目录自己建，裸 xcodebuild test 也能跑。
    func savePreview(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CropmarkBuild")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent(name))
    }

    /// 逐个分页建设置窗口，断言尺寸落在合理区间，并各渲染一张 PNG。
    /// 返回每个分页的实测高度，调用方可以再加自己的断言。
    @MainActor
    @discardableResult
    func renderSettingsTabs(namePrefix: String,
                            file: StaticString = #filePath, line: UInt = #line) throws -> [SettingsTab: CGFloat] {
        var heights: [SettingsTab: CGFloat] = [:]
        for tab in SettingsTab.allCases {
            let controller = SettingsWindowController(initialTab: tab)
            let window = try XCTUnwrap(controller.window, file: file, line: line)
            let content = try XCTUnwrap(window.contentView, file: file, line: line)
            content.layoutSubtreeIfNeeded()
            heights[tab] = content.bounds.height
            // 下界防塌成一条；上界防又退回拆分前那种一页长表单
            XCTAssertGreaterThan(content.bounds.height, SettingsLayout.minHeight,
                                 "\(tab) 内容塌陷: \(content.bounds)", file: file, line: line)
            XCTAssertLessThan(content.bounds.height, SettingsLayout.maxHeight,
                              "\(tab) 过高: \(content.bounds)", file: file, line: line)
            XCTAssertEqual(content.bounds.width, SettingsView.width, file: file, line: line)
            XCTAssertFalse(window.styleMask.contains(.resizable), file: file, line: line)
            try savePreview(content, "\(namePrefix)-\(tab.rawValue).png")
        }
        return heights
    }
}
