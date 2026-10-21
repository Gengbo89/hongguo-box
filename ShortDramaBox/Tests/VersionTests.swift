import XCTest
@testable import ShortDramaBox

/// 「检查更新」的版本号解析与比较。
/// tag 从 build-N 改成 v1.0.N 之后，这里保证解析和比较仍然正确 ——
/// 否则改了 tag 格式，App 里的检查更新会永远说「已是最新」。
@MainActor
final class VersionTests: XCTestCase {

    func testVersionParts() {
        XCTAssertEqual(UpdateChecker.versionParts("1.0.3"), [1, 0, 3])
        XCTAssertEqual(UpdateChecker.versionParts("v1.0.3"), [1, 0, 3])
        XCTAssertEqual(UpdateChecker.versionParts("1.0"), [1, 0])
    }

    func testIsNewer() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.3", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.0", than: "1.0.1"))
        // 10 > 9：必须按数字比，不能按字符串比
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.10", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.1.0", than: "1.0.99"))
    }

    /// atom feed 是「新的在前」，要取第一条，不能取成更老的
    func testLatestTagPrefersNewestEntry() {
        let feed = """
        <feed><title>Release notes from hongguo-box</title>
        <entry><id>tag:github.com,2008:Repository/1/v1.0.2</id>
        <link rel="alternate" type="text/html" href="https://github.com/Gengbo89/hongguo-box/releases/tag/v1.0.2"/>
        <title>短剧盒子 iOS 测试版 1.0.2</title></entry>
        <entry><id>tag:github.com,2008:Repository/1/v1.0.0</id>
        <link rel="alternate" type="text/html" href="https://github.com/Gengbo89/hongguo-box/releases/tag/v1.0.0"/>
        <title>短剧盒子 iOS 测试版 1.0.0</title></entry>
        </feed>
        """
        XCTAssertEqual(UpdateChecker.latestTag(in: feed), "v1.0.2")
    }

    /// 链接匹配不上时，靠标题兜底
    func testLatestTagFromTitleOnly() {
        XCTAssertEqual(UpdateChecker.latestTag(in: "<title>短剧盒子 iOS 测试版 1.0.5</title>"), "1.0.5")
    }

    /// 过渡期 feed 里还留着 build-N，新规则不该误认成版本号
    func testLatestTagIgnoresOldBuildTags() {
        XCTAssertNil(UpdateChecker.latestTag(in: "<title>短剧盒子 iOS 测试版 build 33</title>"))
    }

    /// 「关于」页里版本号和构建号是两行，display 不该再拼构建号
    func testDisplayIsVersionOnly() {
        XCTAssertFalse(AppVersion.display.contains("构建"))
    }
}
