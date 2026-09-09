import XCTest
@testable import Cropmark

@MainActor
final class LocalizationTests: XCTestCase {
    private var english: Bundle {
        get throws {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"), "英文语言包没进 bundle")
            return try XCTUnwrap(Bundle(path: path))
        }
    }

    /// bundle 必须同时声明中英两种语言，否则中文系统会被迫用英文界面
    func testBundleDeclaresBothLanguages() {
        XCTAssertTrue(Bundle.main.localizations.contains("en"), "\(Bundle.main.localizations)")
        XCTAssertTrue(Bundle.main.localizations.contains("zh-Hans"), "\(Bundle.main.localizations)")
        XCTAssertEqual(Bundle.main.developmentLocalization, "zh-Hans")
    }

    /// 每条英文译文都非空、不含中文；格式占位符数量与原文一致
    func testEnglishTableIsComplete() throws {
        let strings = try XCTUnwrap(english.path(forResource: "Localizable", ofType: "strings"))
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: strings) as? [String: String])
        XCTAssertGreaterThan(table.count, 50)
        let cjk = try NSRegularExpression(pattern: "[\\u4e00-\\u9fff「」]")
        for (key, value) in table {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertNil(cjk.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), "译文里还有中文: \(key) → \(value)")
            XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, "占位符数量不一致: \(key)")
        }
    }

    /// 换成英文包后各处文案跟着变；换成没有译文的 bundle（等价于中文系统）时原样返回中文
    func testStringsSwitchWithBundle() throws {
        let original = L10n.bundle
        defer { L10n.bundle = original }
        // 主 bundle 跟随系统语言，这台机器英文优先，所以用测试 bundle（无 Localizable 表）模拟中文系统
        let noTable = Bundle(for: LocalizationTests.self)
        L10n.bundle = try english
        XCTAssertEqual(L10n.t("截图"), "Capture")
        XCTAssertEqual(ToolKind.mosaic.title, "Mosaic")
        XCTAssertEqual(L10n.t("版本 %@", "1.0"), "Version 1.0")
        XCTAssertTrue(Exporter.defaultFileName().hasPrefix("Screenshot "), Exporter.defaultFileName())
        XCTAssertTrue(Exporter.defaultFileName().hasSuffix(".png"))
        L10n.bundle = noTable
        XCTAssertEqual(L10n.t("截图"), "截图")
        XCTAssertTrue(Exporter.defaultFileName().hasPrefix("截屏"))
        XCTAssertEqual(L10n.t("版本 %@", "1.0"), "版本 1.0")
        // 没有译文的键原样返回
        XCTAssertEqual(L10n.t("这条没有翻译"), "这条没有翻译")
    }

    /// 英文版设置页离屏渲染成图，供人工检查排版（长句会不会挤爆）
    func testSettingsRendersInEnglish() throws {
        let original = L10n.bundle
        defer { L10n.bundle = original }
        L10n.bundle = try english
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "Cropmark Settings")
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(content.bounds.height, 380)
        XCTAssertLessThan(content.bounds.height, 1400, "英文版设置页过高: \(content.bounds)")
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/CropmarkBuild")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("preview-6-settings-en.png"))
    }
}
