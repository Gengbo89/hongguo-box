import XCTest
@testable import ShortDramaBox

/// 日志系统自身的测试：写盘、轮转、崩溃记录、清空。
/// 闪退排查全靠它，所以它自己不能坏。
final class LogTests: XCTestCase {

    private func tempLog(maxBytes: Int = 4_000) throws -> HGLog {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hglog-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return HGLog(directory: dir, maxBytes: maxBytes)
    }

    func testWriteAndRead() throws {
        let log = try tempLog()
        log.emit("I", "测试", "你好 hello 123")
        let t = log.text()
        XCTAssertTrue(t.contains("你好 hello 123"), t)
        XCTAssertTrue(t.contains("[I] 测试:"), t)
    }

    func testWriteImmediatelyVisible() throws {
        // 崩溃时进程直接没了，所以写下去必须立刻可读（同步写）
        let log = try tempLog()
        log.emit("E", "测试", "立刻可读")
        XCTAssertTrue(log.text().contains("立刻可读"))
        // 不经过 text()，直接读文件也要有
        let raw = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("立刻可读"), raw)
    }

    func testRotationKeepsLatest() throws {
        let log = try tempLog(maxBytes: 2_000)
        for i in 0..<200 {
            log.emit("I", "测试", "第 \(i) 行 " + String(repeating: "x", count: 40))
        }
        let t = log.text(maxBytes: 1_000_000)
        XCTAssertTrue(t.contains("第 199 行"), "最新一行必须还在：\(t.suffix(200))")
        let old = log.fileURL.deletingLastPathComponent().appendingPathComponent("app.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "应该产生轮转文件")
    }

    func testCrashRecordIsKeptAndShownFirst() throws {
        let log = try tempLog()
        log.emit("I", "测试", "崩之前")
        log.record(kind: "测试崩溃", detail: "name=NSInternalInconsistencyException\nreason=boom")
        let t = log.text()
        XCTAssertTrue(t.contains("crash.log"), t)
        XCTAssertTrue(t.contains("boom"), t)
        XCTAssertTrue(t.contains("崩之前"), t)
        // 崩溃线索排在运行日志前面，方便一眼看到
        XCTAssertLessThan(t.range(of: "boom")!.lowerBound, t.range(of: "崩之前")!.lowerBound)
    }

    func testClearRemovesEverything() throws {
        let log = try tempLog()
        log.emit("I", "测试", "一条")
        log.record(kind: "测试崩溃", detail: "boom")
        log.clear()
        let t = log.text()
        XCTAssertFalse(t.contains("一条"), t)
        XCTAssertFalse(t.contains("boom"), t)
        XCTAssertFalse(log.hadCrashLastRun)
    }

    func testMemoryFootprintIsSane() {
        let m = HGLog.memoryMB()
        XCTAssertGreaterThan(m, 0, "phys_footprint 应该能读到")
        XCTAssertLessThan(m, 20_000, "不该读到离谱的值")
    }
}