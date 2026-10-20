import Foundation

/// 站内搜索：`/search/<关键词>` 是服务端渲染路由，一次返回站方按相关度排序的前 10 条 + 命中总数。
/// 不需要签名，也不依赖本地索引，因此能搜到本地索引里没有的剧（含同名各季）。
enum SearchAPI {
    struct Page {
        var list: [Series] = []
        var total: Int = 0
    }

    static func remote(_ keyword: String) async throws -> Page {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return Page() }
        // 关键词作为路径段，按字节全量百分号编码（中文安全）
        let esc = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? k
        let data = try await httpGet("\(Catalog.base)/search/\(esc)")
        guard let j = routerJSON(data) else { throw ApiError.noData }
        let page = asDict(asDict(j["loaderData"])["search_(keyword)/page"])
        var out = Page()
        out.total = asInt(page["totalCount"])
        for raw in asArr(page["searchList"]) {
            let item = asDict(raw)
            let vd = asDict(item["video_data"])
            let sid = asStr(vd["series_id"])
            guard !sid.isEmpty else { continue }
            var s = Series(id: sid)
            let t = asStr(vd["series_title"])
            s.title = t.isEmpty ? asStr(item["name"]) : t
            s.cover = asStr(vd["series_cover"])
            s.intro = asStr(vd["series_intro"])
            s.episodeCount = asInt(vd["episode_cnt"])
            s.rightText = asStr(vd["episode_right_text"])
            s.tags = asArr(vd["category_list"])
                .map { asStr(asDict($0)["name"]) }
                .filter { !$0.isEmpty }
            out.list.append(s)
        }
        return out
    }
}
