import XCTest
@testable import ShortDramaBox

/// 推荐页「解密中 100%」卡死的回归测试。
///
/// 当时的成因是三个洞叠在一起：
///   1. FeedModel 没有 @MainActor，resolve 在后台线程写 @Published items，
///      而进度回调又特意跳主线程 —— 最终那次 .ready 有没有落到 UI 上看运气；
///   2. pause() 把在飞条目收回 .pending，但取消 Swift 任务停不掉 URLSession 下载，
///      进度回调继续把 .pending 改回 .downloading；
///   3. 被取消的 resolve 直接 return 什么都不写，条目就永久停在 .downloading(1.0)，
///      而 prepareOne 对 .downloading 一律 return —— 不会自愈。
///
/// 文件其实早就下好解密完了，所以点进详情页反而能正常播。
final class FeedStatusTests: XCTestCase {

    private let sample = URL(fileURLWithPath: "/tmp/sample.mp4")

    // MARK: 进度回调不许覆盖终态

    func testProgressCannotClobberReady() {
        XCTAssertFalse(FeedModel.acceptsProgress(.ready(sample)))
    }

    func testProgressCannotClobberFailed() {
        XCTAssertFalse(FeedModel.acceptsProgress(.failed("加载失败")))
    }

    func testProgressCannotRevivePausedItem() {
        // pause() 已把条目收回 .pending，还在飞的下载回调不许把它改回 .downloading
        XCTAssertFalse(FeedModel.acceptsProgress(.pending))
    }

    func testProgressAcceptedOnlyWhileResolvingOrDownloading() {
        XCTAssertTrue(FeedModel.acceptsProgress(.resolving))
        XCTAssertTrue(FeedModel.acceptsProgress(.downloading(0.42)))
    }

    // MARK: 卡住的条目必须能自愈

    func testStuckDownloadingRestartsWhenNoTaskIsRunning() {
        // 核心回归点：停在 100% 且已没有任务在跑 -> 允许重来，不能永远卡死
        XCTAssertTrue(FeedModel.shouldStart(status: .downloading(1.0), inFlight: false))
        XCTAssertTrue(FeedModel.shouldStart(status: .resolving, inFlight: false))
    }

    func testLiveTaskStillWaits() {
        XCTAssertFalse(FeedModel.shouldStart(status: .downloading(0.3), inFlight: true))
        XCTAssertFalse(FeedModel.shouldStart(status: .resolving, inFlight: true))
    }

    func testReadyNeverRestarts() {
        XCTAssertFalse(FeedModel.shouldStart(status: .ready(sample), inFlight: false))
        XCTAssertFalse(FeedModel.shouldStart(status: .ready(sample), inFlight: true))
    }

    func testPendingAndFailedRetry() {
        XCTAssertTrue(FeedModel.shouldStart(status: .pending, inFlight: false))
        XCTAssertTrue(FeedModel.shouldStart(status: .failed("加载失败"), inFlight: false))
    }

    func testLiveTaskBlocksEveryStatus() {
        // 有任务在飞就一律等它，哪怕状态看起来该重试：重复起任务会下两路，
        // 而且旧任务的 defer 会把新任务的 inFlight/tasks 记录一起抹掉。
        XCTAssertFalse(FeedModel.shouldStart(status: .pending, inFlight: true))
        XCTAssertFalse(FeedModel.shouldStart(status: .failed("加载失败"), inFlight: true))
    }
}
