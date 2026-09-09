import XCTest
@testable import Cropmark

/// 自动更新的静态配置：不联网，只检查 Info.plist 里 Sparkle 需要的键是否齐全且格式正确
final class UpdatesConfigTests: XCTestCase {
    func testFeedURLPointsAtRepoAppcast() throws {
        let feed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        let url = try XCTUnwrap(URL(string: feed))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertTrue(feed.hasSuffix("/docs/appcast.xml"), feed)
        XCTAssertTrue(feed.contains("phoxiao/cropmark"), feed)
    }

    /// 公钥必须是 generate_keys 产出的 32 字节 Ed25519 公钥的 base64，占位符会让 Sparkle 拒绝所有更新
    func testPublicKeyIsRealEd25519Key() throws {
        let key = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        XCTAssertNotEqual(key, "REPLACE_WITH_PUBLIC_KEY", "还没填 generate_keys 生成的公钥")
        let bytes = try XCTUnwrap(Data(base64Encoded: key), "公钥不是合法 base64: \(key)")
        XCTAssertEqual(bytes.count, 32)
    }

    func testCheckIntervalIsDaily() throws {
        let interval = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int)
        XCTAssertEqual(interval, 86400)
    }

    /// 测试宿主不启动 Sparkle，设置页要能在 controller 为空时照常渲染
    @MainActor
    func testUpdatesUnavailableInTestHost() {
        XCTAssertFalse(Updates.isAvailable)
        XCTAssertFalse(Updates.automaticallyChecks)
        XCTAssertNil(Updates.lastCheckDate)
        Updates.checkForUpdates()   // 不能崩
    }
}
