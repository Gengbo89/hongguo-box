import XCTest
@testable import ShortDramaBox

/// SSR HTML / 接口字段解析。这些是纯函数，但一旦写错就是「详情页永远打不开」
/// 这种用户立刻能撞上的问题，必须钉死。
final class ParsingTests: XCTestCase {

    // MARK: - routerJSON（大括号配对取 _ROUTER_DATA）

    func testRouterJSONExtractsNestedObject() {
        let html = """
        <!DOCTYPE html><html><head><title>t</title></head><body>
        <script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":\
        {"series_id":"123","series_name":"测试剧","vid_list":["v1","v2"]}}}};</script>
        </body></html>
        """
        let j = routerJSON(Data(html.utf8))
        XCTAssertNotNil(j)
        let sd = asDict(asDict(asDict(j!["loaderData"])["detail_page"])["seriesDetail"])
        XCTAssertEqual(asStr(sd["series_id"]), "123")
        XCTAssertEqual(asStr(sd["series_name"]), "测试剧")
        XCTAssertEqual(asArr(sd["vid_list"]).count, 2)
    }

    /// 字符串里带花括号和转义引号时，配对不能被带偏（这是最容易写错的地方）
    func testRouterJSONIgnoresBracesInsideStrings() {
        let html = #"""
        <script>window._ROUTER_DATA = {"a":"}{ not real {","b":"say \"hi\" }","c":{"d":1}};</script>
        """#
        let j = routerJSON(Data(html.utf8))
        XCTAssertNotNil(j, "字符串里的花括号把配对带偏了")
        XCTAssertEqual(asStr(j!["a"]), "}{ not real {")
        XCTAssertEqual(asInt(asDict(j!["c"])["d"]), 1)
    }

    /// 反斜杠转义链：\\" 结尾时不能把后面的引号当成字符串开头
    func testRouterJSONHandlesEscapedBackslashBeforeQuote() {
        let html = #"""
        <script>window._ROUTER_DATA = {"p":"C:\\","q":{"ok":true}};</script>
        """#
        let j = routerJSON(Data(html.utf8))
        XCTAssertNotNil(j, "反斜杠转义处理有误")
        XCTAssertEqual(asStr(j!["p"]), #"C:\"#)
        XCTAssertEqual(asDict(j!["q"])["ok"] as? Bool, true)
    }

    func testRouterJSONReturnsNilWhenMarkerMissing() {
        XCTAssertNil(routerJSON(Data("<html>nothing here</html>".utf8)))
    }

    func testRouterJSONReturnsNilWhenUnterminated() {
        // 只有左括号、没有收口 —— 不能崩，返回 nil
        XCTAssertNil(routerJSON(Data(#"<script>_ROUTER_DATA = {"a":{"b":1"#.utf8)))
    }

    func testRouterJSONReturnsNilOnNonUTF8() {
        XCTAssertNil(routerJSON(Data([0xFF, 0xFE, 0xFD])))
    }

    // MARK: - 类型强转（接口里同一个字段可能是数字也可能是字符串）

    func testNumberStringCoercion() {
        XCTAssertEqual(asStr(NSNumber(value: 123)), "123")
        XCTAssertEqual(asStr("abc"), "abc")
        XCTAssertEqual(asStr(nil), "")
        XCTAssertEqual(asStr([1, 2]), "")

        XCTAssertEqual(asInt(NSNumber(value: 42)), 42)
        XCTAssertEqual(asInt("42"), 42)        // 字符串数字要认
        XCTAssertEqual(asInt("abc"), 0)
        XCTAssertEqual(asInt(nil), 0)

        XCTAssertTrue(asDict(nil).isEmpty)
        XCTAssertTrue(asArr(nil).isEmpty)
        XCTAssertTrue(asArr("not an array").isEmpty)
    }

    // MARK: - seriesFrom 字段映射

    func testSeriesFromPrefersSeriesName() {
        let s = seriesFrom(["series_id": "9", "series_name": "正名", "series_title": "别名",
                            "episode_cnt": "12", "tags": ["都市", "", "逆袭"]])
        XCTAssertEqual(s.id, "9")
        XCTAssertEqual(s.title, "正名")
        XCTAssertEqual(s.episodeCount, 12)
        XCTAssertEqual(s.tags, ["都市", "逆袭"], "空标签没被过滤")
    }

    func testSeriesFromFallsBackToSeriesTitle() {
        let s = seriesFrom(["series_id": "9", "series_title": "只有别名"])
        XCTAssertEqual(s.title, "只有别名")
    }

    func testSeriesFromTolerantOfMissingFields() {
        let s = seriesFrom([:])
        XCTAssertEqual(s.id, "")
        XCTAssertEqual(s.title, "")
        XCTAssertEqual(s.episodeCount, 0)
        XCTAssertTrue(s.tags.isEmpty)
    }
}
