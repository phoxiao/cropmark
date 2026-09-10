import XCTest
import SwiftUI
@testable import Cropmark

@MainActor
final class SettingsRenderTests: XCTestCase {
    /// 中文版设置页：每个分页都要有实际高度，窗口高度确实跟着分页走，各渲染一张图。
    ///
    /// 必须显式换掉 L10n.bundle：主 bundle 跟随系统语言，这台机器英文优先，
    /// 不换的话渲染出来的是英文，中文排版一张都验不到（英文版由 LocalizationTests 负责）。
    /// 测试 bundle 里没有 Localizable 表，查不到译文就原样返回中文键，等价于中文系统。
    func testEachTabRendersInChinese() throws {
        let original = L10n.bundle
        defer { L10n.bundle = original }
        L10n.bundle = Bundle(for: SettingsRenderTests.self)
        XCTAssertEqual(L10n.t("Cropmark 设置"), "Cropmark 设置", "没换成中文，后面渲染的就不是中文版")

        let heights = try renderSettingsTabs(namePrefix: "preview-5-settings")

        // 四个分页不该是同一个高度，否则说明窗口没跟着内容走
        let general = try XCTUnwrap(heights[.general])
        let keys = try XCTUnwrap(heights[.keys])
        XCTAssertGreaterThan(general - keys, 80, "各分页高度没有区分: \(heights)")
    }
}
