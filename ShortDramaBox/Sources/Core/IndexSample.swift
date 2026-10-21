import Foundation

/// 索引缓存的**低内存随机抽样**。
///
/// 背景（这是「看着看着闪退」的根因之一）：
/// 推荐页原来走 `Catalog.loadIndexCache()` ——
/// `Data(contentsOf:)` 把整份 JSON 读进来，再 `JSONDecoder().decode([Series].self)`
/// 把全部 58 万条解成 struct，接着还要 `Set` 去重、`shuffled()`、`map` 成 FeedItem，
/// 连着好几份全量数组同时在内存里，峰值几百 MB 且常驻不释放。
/// 一边播 1080p（解码器本身也要内存）一边扛着这么大一块，
/// 就是被系统 jetsam 杀掉的那个「看着看着闪退」。
///
/// 这里改成**流式扫描 + 蓄水池抽样**：
/// 顺序扫一遍索引文件，内存里只留 limit 条记录的字节区间，扫完再逐条解码。
/// 抽样是均匀随机的，总量也如实返回（界面上照旧显示「全量片库 588787 部」）。
extension Catalog {
    static func sampleIndexCache(limit: Int = 240,
                                 maxAge: TimeInterval = 60 * 60 * 24 * 7
    ) -> (list: [Series], total: Int, age: TimeInterval)? {
        guard limit > 0 else { return nil }
        let u = indexCacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
              let mod = attrs[.modificationDate] as? Date else { return nil }
        let age = Date().timeIntervalSince(mod)
        if age > maxAge { return nil }
        guard let fh = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? fh.close() }

        var ranges: [(Int, Int)] = []
        var total = 0
        var depth = 0
        var inStr = false, esc = false
        var recStart = -1
        var off = 0
        var sawArrayStart = false

        let chunkSize = 1 << 20
        scan: while true {
            guard let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            for b in chunk {
                if !sawArrayStart {
                    // 只认自家写的 JSON 数组（首个非空白字节是 '['）。
                    // 别的格式直接放弃，让推荐页退回首页/分类内容，不冒险猜格式。
                    if b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09 { off += 1; continue }
                    guard b == 0x5b else { return nil }
                    sawArrayStart = true
                    depth = 1
                    off += 1
                    continue
                }
                if inStr {
                    if esc { esc = false }
                    else if b == 0x5c { esc = true }
                    else if b == 0x22 { inStr = false }
                } else {
                    switch b {
                    case 0x22:
                        inStr = true
                    case 0x7b, 0x5b:                       // { 或 [
                        if depth == 1 && recStart < 0 { recStart = off }
                        depth += 1
                    case 0x7d, 0x5d:                       // } 或 ]
                        depth -= 1
                        if depth == 1, recStart >= 0 {
                            total += 1
                            if ranges.count < limit {
                                ranges.append((recStart, off + 1))
                            } else {
                                // 蓄水池抽样：第 total 条以 limit/total 的概率入选
                                let j = Int.random(in: 0..<total)
                                if j < limit { ranges[j] = (recStart, off + 1) }
                            }
                            recStart = -1
                        }
                        if depth <= 0 { off += 1; break scan }
                    default:
                        break
                    }
                }
                off += 1
            }
        }

        guard total > 0, !ranges.isEmpty else { return nil }
        let dec = JSONDecoder()
        var list: [Series] = []
        list.reserveCapacity(ranges.count)
        for (s, e) in ranges where e > s {
            guard (try? fh.seek(toOffset: UInt64(s))) != nil,
                  let d = try? fh.read(upToCount: e - s), d.count == e - s,
                  let one = try? dec.decode(Series.self, from: d) else { continue }
            list.append(one)
        }
        guard !list.isEmpty else { return nil }
        return (list, total, age)
    }
}