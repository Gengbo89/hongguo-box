import XCTest
@testable import ShortDramaBox

/// 内置全库索引（58.8 万部，自定义二进制格式）。
/// 标签倒排是按字节偏移直接读的，最容易「不报错但悄悄少一半」，
/// 所以除了分页，还用「每条记录自带的标签」反向交叉验证倒排结果。
final class IndexTests: XCTestCase {

    override func setUpWithError() throws {
        _ = LocalIndex.shared.tagBuckets()
    }

    func testIndexIsLoaded() {
        XCTAssertTrue(LocalIndex.shared.isReady, "内置索引没加载起来")
        XCTAssertGreaterThan(LocalIndex.shared.totalCount, 500_000, "记录数只有 \(LocalIndex.shared.totalCount)")
        XCTAssertGreaterThan(LocalIndex.shared.allTags.count, 300, "标签只有 \(LocalIndex.shared.allTags.count) 个")
    }

    func testTagBucketsAreSortedAndNonEmpty() {
        let buckets = LocalIndex.shared.tagBuckets()
        XCTAssertFalse(buckets.isEmpty, "一个标签都没扫出来")
        for i in 1..<buckets.count {
            XCTAssertGreaterThanOrEqual(buckets[i-1].count, buckets[i].count, "标签没按数量排序")
        }
        for b in buckets {
            XCTAssertFalse(b.tag.isEmpty, "出现空标签")
            XCTAssertGreaterThan(b.count, 0, "标签「\(b.tag)」数量是 0")
        }
        XCTAssertEqual(Set(buckets.map { $0.tag }).count, buckets.count, "标签有重复")
    }

    func testTagPagingIsDisjointAndCounted() {
        guard let top = LocalIndex.shared.tagBuckets().first else { return XCTFail("没有标签") }
        let p1 = LocalIndex.shared.series(tag: top.tag, offset: 0, limit: 24)
        let p2 = LocalIndex.shared.series(tag: top.tag, offset: 24, limit: 24)
        XCTAssertEqual(p1.total, top.count, "total 和标签统计对不上")
        XCTAssertEqual(p1.total, LocalIndex.shared.tagCount(top.tag), "tagCount 对不上")
        XCTAssertEqual(p1.items.count, min(24, top.count))
        if top.count > 24 {
            XCTAssertEqual(p2.items.count, min(24, top.count - 24))
            XCTAssertTrue(Set(p1.items.map { $0.id }).isDisjoint(with: Set(p2.items.map { $0.id })), "两页有重复")
        }
        for s in p1.items {
            XCTAssertFalse(s.id.isEmpty, "条目没有 id")
            XCTAssertFalse(s.title.isEmpty, "条目 \(s.id) 没有标题")
            XCTAssertGreaterThan(s.episodeCount, 0, "条目 \(s.title) 集数是 0")
        }
    }

    /// 交叉验证：倒排说「这些记录有这个标签」，就拿记录自己的标签复核
    func testInvertedIndexMatchesPerRecordTags() {
        for b in LocalIndex.shared.tagBuckets().prefix(12) {
            let page = LocalIndex.shared.series(tag: b.tag, offset: 0, limit: 10)
            XCTAssertFalse(page.items.isEmpty, "标签「\(b.tag)」有 \(b.count) 条却取不出来")
            for s in page.items {
                XCTAssertTrue(s.tags.contains(b.tag),
                              "「\(s.title)」出现在标签「\(b.tag)」下，但它自己的标签是 \(s.tags)")
            }
        }
    }

    func testUnknownTagIsEmpty() {
        let ghost = "不存在的标签-\(UUID().uuidString)"
        let r = LocalIndex.shared.series(tag: ghost, offset: 0, limit: 10)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.total, 0)
        XCTAssertEqual(LocalIndex.shared.tagCount(ghost), 0)
    }

    func testPastTheEndReturnsNothingButKeepsTotal() {
        guard let top = LocalIndex.shared.tagBuckets().first else { return XCTFail("没有标签") }
        let r = LocalIndex.shared.series(tag: top.tag, offset: top.count + 1000, limit: 24)
        XCTAssertTrue(r.items.isEmpty, "越界了还返回内容")
        XCTAssertEqual(r.total, top.count, "越界时 total 不该丢")
    }

    func testSeriesAtBoundsDoesNotCrash() {
        XCTAssertNil(LocalIndex.shared.series(at: -1))
        XCTAssertNil(LocalIndex.shared.series(at: LocalIndex.shared.totalCount))
        XCTAssertNil(LocalIndex.shared.series(at: 999_999_999))
        XCTAssertNotNil(LocalIndex.shared.series(at: 0))
    }

    /// 拿真实记录的标题去搜，必须能搜回它自己。
    /// search 的关键词上限是 64 字节（超了直接返回空），所以挑长度合适的记录。
    func testSearchFindsTheRecordItCameFrom() {
        var picked: Series?
        for i in 0..<80 {
            guard let s = LocalIndex.shared.series(at: i) else { break }
            let n = s.title.lengthOfBytes(using: .utf8)
            if n >= 6 && n <= 60 { picked = s; break }
        }
        guard let s0 = picked else { return XCTFail("前 80 条里没有标题长度合适的记录") }
        let r = LocalIndex.shared.search(s0.title)
        XCTAssertGreaterThan(r.total, 0, "用自己的标题「\(s0.title)」都搜不到")
        XCTAssertTrue(r.list.contains { $0.id == s0.id }, "搜索结果里没有它自己（总数 \(r.total)）")
    }

    func testOverlongKeywordIsRejectedSafely() {
        let r = LocalIndex.shared.search(String(repeating: "剧", count: 100))
        XCTAssertTrue(r.list.isEmpty, "超长关键词居然命中了 \(r.total) 条")
    }

    func testSearchResultLimitIsRespected() {
        XCTAssertLessThanOrEqual(LocalIndex.shared.search("剧", limit: 5).list.count, 5)
    }

    /// 倒排建好后翻页应该是切片，不是每次全表扫描
    func testPagingIsFastAfterWarmUp() {
        guard let top = LocalIndex.shared.tagBuckets().first else { return XCTFail("没有标签") }
        _ = LocalIndex.shared.series(tag: top.tag, offset: 0, limit: 24)
        let t0 = Date()
        for i in 0..<20 { _ = LocalIndex.shared.series(tag: top.tag, offset: i * 24, limit: 24) }
        let dt = Date().timeIntervalSince(t0)
        XCTAssertLessThan(dt, 2.0, "20 次翻页用了 \(String(format: "%.3f", dt)) 秒")
    }
}
