import XCTest
@testable import ShortDramaBox

/// 全局播放权仲裁。
///
/// 这个类型的存在就是因为出过「推荐页两个视频同时出声」的 bug，
/// 所以它的每条语义都要钉住：谁最后申请，谁就把上一个停掉；
/// 自己重复申请不能把自己停了；归还时不能把后来者的播放权一起抹掉。
final class PlaybackCenterTests: XCTestCase {

    private var center: PlaybackCenter { PlaybackCenter.shared }

    /// stop 回调可能被派回主线程执行，断言前先把主队列跑空，
    /// 免得因为调度时序让用例时好时坏。
    private func drain() {
        let e = expectation(description: "drain")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 5)
    }

    override func setUp() {
        super.setUp()
        // 每个用例从干净状态开始
        center.release("A"); center.release("B"); center.release("C"); center.release("D")
    }

    func testFirstClaimStopsNobody() {
        var stopped: [String] = []
        center.claim("A") { stopped.append("A") }
        drain()
        XCTAssertTrue(stopped.isEmpty, "第一个申请者不该被停")
    }

    func testSecondClaimStopsTheFirst() {
        var stopped: [String] = []
        center.claim("A") { stopped.append("A") }
        center.claim("B") { stopped.append("B") }
        drain()
        XCTAssertEqual(stopped, ["A"], "新申请者没把上一个停掉 —— 两个视频会同时出声")
    }

    /// 同一个 id 重复申请（列表里同一张卡反复出现）不能把自己停掉
    func testReclaimingSameIdDoesNotStopItself() {
        var stopped: [String] = []
        center.claim("A") { stopped.append("A") }
        center.claim("A") { stopped.append("A") }
        center.claim("A") { stopped.append("A") }
        drain()
        XCTAssertTrue(stopped.isEmpty, "自己重复申请把自己停了：\(stopped)")
    }

    /// 重新申请时应该换成**新的** stop 闭包（旧的可能捕获了已经销毁的播放器）
    func testReclaimReplacesStopClosure() {
        var stopped: [String] = []
        center.claim("A") { stopped.append("old") }
        center.claim("A") { stopped.append("new") }
        center.claim("B") { stopped.append("B") }
        drain()
        XCTAssertEqual(stopped, ["new"], "停的是旧闭包，说明重新申请没换掉 stop")
    }

    func testReleaseThenClaimStopsNobody() {
        var stopped: [String] = []
        center.claim("A") { stopped.append("A") }
        center.release("A")
        center.claim("B") { stopped.append("B") }
        drain()
        XCTAssertTrue(stopped.isEmpty, "已经归还的 A 还被停了一次")
    }

    /// 归还时必须确认「我还持有」，否则会把后来者的播放权一起抹掉
    func testStaleReleaseDoesNotStealOwnershipFromTheNewOwner() {
        var stopped: [String] = []
        center.claim("A") { stopped.append("A") }
        center.claim("B") { stopped.append("B") }   // A 被停，B 持有
        center.release("A")                        // A 迟到的归还
        center.claim("C") { stopped.append("C") }   // 应该停 B，而不是「没人持有」
        drain()
        XCTAssertEqual(stopped, ["A", "B"], "迟到的归还把 B 的播放权抹掉了")
    }

    func testReleaseUnknownIdIsHarmless() {
        var stopped: [String] = []
        center.release("从来没申请过")
        center.claim("A") { stopped.append("A") }
        drain()
        XCTAssertTrue(stopped.isEmpty)
    }

    /// 反复申请/归还也不能把状态搞乱（推荐页快速滑动就是这个节奏）
    func testChurnKeepsSingleOwner() {
        var stopped: [String] = []
        for i in 0..<50 {
            center.claim("A") { stopped.append("A") }
            center.release("A")
            center.claim("B") { stopped.append("B") }
            center.release("B")
            _ = i
        }
        drain()
        XCTAssertTrue(stopped.isEmpty, "反复申请归还时误停了 \(stopped.count) 次")
        // 最后一次留下的是 B 归还后的空状态
        center.claim("C") { stopped.append("C") }
        drain()
        XCTAssertTrue(stopped.isEmpty)
    }

    /// 多线程同时抢：不能崩、不能死锁（锁实现的基本要求）
    func testConcurrentClaimReleaseDoesNotDeadlockOrCrash() {
        let exp = expectation(description: "并发抢播放权")
        exp.expectedFulfillmentCount = 8
        for t in 0..<8 {
            DispatchQueue.global().async {
                for i in 0..<200 {
                    let id = "T\(t)-\(i % 3)"
                    self.center.claim(id) { }
                    self.center.release(id)
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)
    }
}
