import XCTest
@testable import ShortDramaBox

/// 观看记录。上限、去重、删除三件事，错了就是「记录越滚越大」或「删不掉」。
final class WatchStoreTests: XCTestCase {

    private let prefix = "ut-\(UUID().uuidString.prefix(8))-"

    private func cleanup(_ store: WatchStore) {
        for s in store.items where s.seriesId.hasPrefix(prefix) {
            store.remove(seriesId: s.seriesId)
        }
    }

    func testRecordThenFind() {
        let store = WatchStore()
        let id = prefix + "one"
        store.record(seriesId: id, title: "测试剧", cover: "c", episode: 3, seconds: 12.5)
        XCTAssertTrue(store.items.contains { $0.seriesId == id }, "刚记的观看记录找不到")
        cleanup(store)
    }

    /// 同一部剧重复记录只能有一条（不然「继续观看」会列出十几个重复封面）
    func testSameSeriesDoesNotDuplicate() {
        let store = WatchStore()
        let id = prefix + "dup"
        store.record(seriesId: id, title: "测试剧", cover: "c", episode: 1, seconds: 1)
        store.record(seriesId: id, title: "测试剧", cover: "c", episode: 2, seconds: 2)
        store.record(seriesId: id, title: "测试剧", cover: "c", episode: 3, seconds: 3)
        XCTAssertEqual(store.items.filter { $0.seriesId == id }.count, 1, "同一部剧出现了多条记录")
        cleanup(store)
    }

    func testRemoveDeletesIt() {
        let store = WatchStore()
        let id = prefix + "del"
        store.record(seriesId: id, title: "测试剧", cover: "c", episode: 1, seconds: 1)
        store.remove(seriesId: id)
        XCTAssertFalse(store.items.contains { $0.seriesId == id }, "删了还在")
    }

    /// 上限：不能无限增长（用户记录几百部之后 App 会变卡）
    func testHistoryIsCapped() {
        let store = WatchStore()
        for i in 0..<130 {
            store.record(seriesId: prefix + "cap\(i)", title: "剧\(i)", cover: "c",
                         episode: 1, seconds: Double(i))
        }
        XCTAssertLessThanOrEqual(store.items.count, 100,
                                 "观看记录涨到了 \(store.items.count) 条，没有被截断")
        XCTAssertGreaterThan(store.items.count, 0)
        cleanup(store)
    }

    func testCleanupLeavesNoTestResidue() {
        let store = WatchStore()
        cleanup(store)
        XCTAssertFalse(store.items.contains { $0.seriesId.hasPrefix(prefix) },
                       "测试数据没清干净，会污染真实观看记录")
    }
}
