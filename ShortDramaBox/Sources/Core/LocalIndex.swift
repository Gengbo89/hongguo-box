import Foundation
import Compression

/// 内置全库索引：约 58.8 万部短剧的 id / 片名 / 封面hash / 集数 / 标签。
///
/// `index.bin.z` 格式（小端）：
///   u64 rawSize  （以下正文解压后的字节数）
///   --- raw deflate 压缩的正文 ---
///   'DJIX' | u32 version | u32 count | u32 tagCount
///   tags         [u16 len + UTF-8] × tagCount
///   pad          对齐到 8
///   titleOffsets u32 × (count+1)
///   titleBlob    UTF-8 片名拼接
///   ids          u64 × count（升序）
///   coverHashes  16B × count
///   eps          u16 × count
///   tagCounts    u8  × count
///   tagRefs      u16 × total
///   created      u32 × count（版本 2 起：上架时间，Unix 秒）
///
/// 刻意不把 58.8 万条解析成 Swift 对象（那要几百 MB 内存），
/// 而是保留一整块 Data，搜索时在片名 blob 上做字节扫描，
/// 命中后用二分查找定位记录，最后才按需构造 Series。
final class LocalIndex {
    static let shared = LocalIndex()

    /// 封面按 hash 统一从该主机重建：接口返回的原始 URL 带签名会过期，不能存。
    private static let coverHost = "https://p6-novel.byteimg.com/novel-pic/"
    private static let coverTail = "~tplv-shrink:640:0.image"

    private var data: Data?
    private var count = 0
    private var tagTable: [String] = []

    private var titleOffOff = 0
    private var titleBlobOff = 0
    private var idsOff = 0
    private var coversOff = 0
    private var epsOff = 0
    private var tagCountsOff = 0
    private var tagRefsOff = 0
    /// 版本 2 起正文末尾 created(u32×count) 的起始偏移；旧格式为 -1。
    private var createdOff = -1
    /// 每条记录在 tagRefs 里的起始下标（前缀和）。
    /// 标签引用是变长的，不预计算的话每次取标签都要从第 0 条累加到目标下标。
    private var tagPrefix: [Int32] = []
    private var titleBlobLen = 0

    /// 标签 → 记录下标的倒排索引。首次用到才建（约 0.3~1 秒、约 7 MB），
    /// 之后按标签翻库就是直接切片，不再全表扫描。
    private var tagIndex: [[Int32]]?

    /// 「最新在前」的记录下标顺序，建倒排时用；也只算一次。
    private var orderCache: [Int32]?

    private var loadFailed = false
    private var loaded = false
    private let lock = NSLock()

    private init() {}

    var isReady: Bool {
        load()
        return data != nil && count > 0
    }

    var totalCount: Int {
        load()
        return count
    }

    var allTags: [String] {
        load()
        return tagTable
    }

    // MARK: - 装载

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return }
        loaded = true
        // 日志挪到锁后面：并发调用只打一行，不再刷十几行噪声
        HGLog.i("索引", "开始加载本地全库索引")
        guard let url = Bundle.main.url(forResource: "index.bin", withExtension: "z"),
              let packed = try? Data(contentsOf: url, options: .mappedIfSafe),
              packed.count > 8 else { return }
        let rawSize = packed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) }
        guard rawSize > 16, rawSize < 512 * 1024 * 1024 else { return }
        let payload = packed.subdata(in: 8..<packed.count)
        var out = Data(count: Int(rawSize))
        let decoded: Int = out.withUnsafeMutableBytes { dst -> Int in
            guard let d = dst.baseAddress else { return 0 }
            return payload.withUnsafeBytes { src -> Int in
                guard let s = src.baseAddress else { return 0 }
                // Apple 的 COMPRESSION_ZLIB 就是裸 DEFLATE
                return compression_decode_buffer(d.assumingMemoryBound(to: UInt8.self), Int(rawSize),
                                                 s.assumingMemoryBound(to: UInt8.self), payload.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == Int(rawSize), out.count > 16, out.prefix(4) == Data("DJIX".utf8) else { return }

        let hdr = out.withUnsafeBytes { p -> (UInt32, UInt32, UInt32) in
            (p.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
             p.loadUnaligned(fromByteOffset: 8, as: UInt32.self),
             p.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        }
        let ver = hdr.0
        let n = Int(hdr.1)
        let tagCount = Int(hdr.2)
        guard n > 0, tagCount >= 0, tagCount < 100_000 else { return }

        var tags: [String] = []
        tags.reserveCapacity(tagCount)
        var p = 16
        for _ in 0..<tagCount {
            guard p + 2 <= out.count else { return }
            let len = Int(out.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: UInt16.self) })
            p += 2
            guard len >= 0, p + len <= out.count else { return }
            tags.append(String(decoding: out[(out.startIndex + p)..<(out.startIndex + p + len)], as: UTF8.self))
            p += len
        }
        while p % 8 != 0 { p += 1 }

        guard p + (n + 1) * 4 + n * 8 <= out.count else { return }
        titleOffOff = p
        titleBlobOff = titleOffOff + (n + 1) * 4
        titleBlobLen = Int(out.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: titleOffOff + n * 4, as: UInt32.self)
        })
        guard titleBlobLen >= 0 else { return }
        idsOff = titleBlobOff + titleBlobLen
        coversOff = idsOff + n * 8
        epsOff = coversOff + n * 16
        tagCountsOff = epsOff + n * 2
        tagRefsOff = tagCountsOff + n
        guard idsOff <= out.count, coversOff <= out.count, epsOff <= out.count,
              tagCountsOff + n <= out.count else { return }

        // 一次扫出前缀和：装载时 O(count)，换掉之后每次查询的 O(index)
        var pref = [Int32](repeating: 0, count: n + 1)
        out.withUnsafeBytes { p in
            var acc: Int32 = 0
            var i = 0
            while i < n {
                pref[i] = acc
                acc += Int32(p.loadUnaligned(fromByteOffset: tagCountsOff + i, as: UInt8.self))
                i += 1
            }
            pref[n] = acc
        }
        tagPrefix = pref

        // 版本 2 起：正文在 tagRefs 之后追加 created(u32 × count)
        createdOff = -1
        if ver >= 2 {
            let after = tagRefsOff + Int(pref[n]) * 2
            if after + n * 4 <= out.count { createdOff = after }
        }
        orderCache = nil

        tagTable = tags
        count = n
        data = out
    }

    // MARK: - 取记录

    func series(at index: Int) -> Series? {
        load()
        guard let d = data, index >= 0, index < count else { return nil }
        let title = d.withUnsafeBytes { p -> String in
            let s = Int(p.loadUnaligned(fromByteOffset: titleOffOff + index * 4, as: UInt32.self))
            let e = Int(p.loadUnaligned(fromByteOffset: titleOffOff + (index + 1) * 4, as: UInt32.self))
            guard e >= s, titleBlobOff + e <= d.count else { return "" }
            return String(decoding: d[(d.startIndex + titleBlobOff + s)..<(d.startIndex + titleBlobOff + e)], as: UTF8.self)
        }
        guard !title.isEmpty else { return nil }
        let idv = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: idsOff + index * 8, as: UInt64.self) }
        let ep = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: epsOff + index * 2, as: UInt16.self) }
        var cover = ""
        if coversOff + (index + 1) * 16 <= d.count {
            let hex = Self.hex(d[(coversOff + index * 16)..<(coversOff + index * 16 + 16)])
            if hex != String(repeating: "0", count: 32) {
                cover = Self.coverHost + hex + Self.coverTail
            }
        }
        var s = Series(id: String(idv), title: title, cover: cover)
        s.episodeCount = Int(ep)
        s.tags = tags(at: index)
        return s
    }

    /// 字节转十六进制。String(format:) 每次要 1μs 量级，
    /// 一条记录 16 个字节、一次搜索几百条就是几千次，查表几乎免费。
    private static let hexChars: [UInt8] = Array("0123456789abcdef".utf8)
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out = [UInt8]()
        out.reserveCapacity(32)
        for b in bytes {
            out.append(hexChars[Int(b >> 4)])
            out.append(hexChars[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func tags(at index: Int) -> [String] {
        guard let d = data, tagCountsOff + index < d.count, !tagTable.isEmpty else { return [] }
        let n = Int(d[tagCountsOff + index])
        guard n > 0 else { return [] }
        guard index + 1 < tagPrefix.count else { return [] }
        let base = Int(tagPrefix[index])
        var out: [String] = []
        out.reserveCapacity(n)
        d.withUnsafeBytes { p in
            var k = 0
            while k < n {
                let off = tagRefsOff + (base + k) * 2
                guard off + 2 <= d.count else { return }
                let ti = Int(p.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                if ti >= 0 && ti < tagTable.count { out.append(tagTable[ti]) }
                k += 1
            }
        }
        return out
    }

    // MARK: - 标签浏览

    /// 一个标签及其剧集数
    struct TagBucket {
        var tag: String
        var count: Int
    }

    /// 记录的「最新在前」顺序：created 倒序，同一秒内按下标（≈id）倒序。
    private func timeDescOrder() -> [Int32] {
        if let o = orderCache { return o }
        var o: [Int32] = []
        if createdOff >= 0, let d = data, count > 0 {
            // 打包成一个 UInt64 排序（高 32 位 created、低 32 位下标），
            // 比带闭包的比较器快得多。
            var keys = [UInt64](repeating: 0, count: count)
            d.withUnsafeBytes { p in
                for i in 0..<count {
                    let c = UInt64(p.loadUnaligned(fromByteOffset: createdOff + i * 4, as: UInt32.self))
                    keys[i] = (c << 32) | UInt64(i)
                }
            }
            keys.sort(by: >)
            o = keys.map { Int32(truncatingIfNeeded: $0) }
        } else {
            // 旧格式没有时间字段：id 升序≈时间升序，倒着来最接近「最新在前」
            o = (0..<max(count, 0)).reversed().map { Int32($0) }
        }
        orderCache = o
        return o
    }

    /// 该记录的上架时间（Unix 秒）。格式版本 2 起才有；没有则返回 0。
    func created(at index: Int) -> UInt32 {
        load()
        guard let d = data, createdOff >= 0, index >= 0, index < count,
              createdOff + (index + 1) * 4 <= d.count else { return 0 }
        return d.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: createdOff + index * 4, as: UInt32.self)
        }
    }

    // MARK: - 推荐流取样

    /// 「新剧」：按「最新在前」（created 倒序）取一段，解码成可播的记录。
    /// - Parameters:
    ///   - offset: 上次返回到的 `next`（跨批次不重复）
    ///   - limit: 本批最多要几条
    /// - Returns: `items` 本批记录；`next` 下次的起点。个别记录被截断会顺延，
    ///   所以最多往后多看 3 倍下标，避免一条坏数据卡住整条流。
    func newest(offset: Int, limit: Int) -> (items: [Series], next: Int) {
        load()
        guard limit > 0, data != nil, count > 0 else { return ([], max(0, offset)) }
        let ord = timeDescOrder()
        var out: [Series] = []
        out.reserveCapacity(limit)
        var i = max(0, min(offset, ord.count))
        let stop = min(ord.count, i + limit * 3)
        while i < stop, out.count < limit {
            if let s = series(at: Int(ord[i])) { out.append(s) }
            i += 1
        }
        return (out, i)
    }

    /// 「其他剧」：从全库（58.8 万条）均匀随机抽 `limit` 条，跳过 `excluding` 里的 id。
    /// 重复命中会重抽，所以实际条数可能略少；调用方按返回条数用。
    func randomSeries(limit: Int, excluding: Set<String> = []) -> [Series] {
        load()
        guard limit > 0, data != nil, count > 0 else { return [] }
        var out: [Series] = []
        out.reserveCapacity(limit)
        var seen = excluding
        var attempts = 0
        let maxAttempts = limit * 6
        while out.count < limit, attempts < maxAttempts {
            attempts += 1
            guard let s = series(at: Int.random(in: 0..<count)) else { continue }
            guard seen.insert(s.id).inserted else { continue }
            out.append(s)
        }
        return out
    }


    /// 建倒排索引。两趟扫描：先数个数把容量开好（避免反复扩容），再灌。
    /// 按「最新在前」的顺序扫，所以每个标签的列表天然就是时间倒序，
    /// 分类页翻页时直接切片即可，不需要在查询时再排序。
    private func buildTagIndex() -> [[Int32]] {
        load()
        lock.lock()
        defer { lock.unlock() }
        if let t = tagIndex { return t }
        let ord = timeDescOrder()
        var lists: [[Int32]] = []
        if let d = data, count > 0, !tagTable.isEmpty, tagPrefix.count > count {
            lists = [[Int32]](repeating: [], count: tagTable.count)
            var counts = [Int32](repeating: 0, count: tagTable.count)
            d.withUnsafeBytes { raw in
                for oi in ord {
                    let i = Int(oi)
                    let n = Int(raw.loadUnaligned(fromByteOffset: tagCountsOff + i, as: UInt8.self))
                    guard n > 0 else { continue }
                    let base = Int(tagPrefix[i])
                    for k in 0..<n {
                        let off = tagRefsOff + (base + k) * 2
                        guard off + 2 <= d.count else { break }
                        let ti = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                        if ti >= 0 && ti < counts.count { counts[ti] += 1 }
                    }
                }
            }
            for i in 0..<lists.count { lists[i].reserveCapacity(Int(counts[i])) }
            d.withUnsafeBytes { raw in
                for oi in ord {
                    let i = Int(oi)
                    let n = Int(raw.loadUnaligned(fromByteOffset: tagCountsOff + i, as: UInt8.self))
                    guard n > 0 else { continue }
                    let base = Int(tagPrefix[i])
                    for k in 0..<n {
                        let off = tagRefsOff + (base + k) * 2
                        guard off + 2 <= d.count else { break }
                        let ti = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
                        if ti >= 0 && ti < lists.count { lists[ti].append(Int32(i)) }
                    }
                }
            }
        }
        tagIndex = lists
        return lists
    }

    /// 全部标签，按剧集数从多到少（分类页用）。空标签不返回。
    func tagBuckets() -> [TagBucket] {
        let lists = buildTagIndex()
        var out: [TagBucket] = []
        out.reserveCapacity(lists.count)
        for (i, l) in lists.enumerated() where !l.isEmpty && i < tagTable.count {
            out.append(TagBucket(tag: tagTable[i], count: l.count))
        }
        out.sort { $0.count > $1.count }
        return out
    }

    func tagCount(_ tag: String) -> Int {
        let lists = buildTagIndex()
        guard let ti = tagTable.firstIndex(of: tag), ti < lists.count else { return 0 }
        return lists[ti].count
    }

    /// 按标签翻库。offset/limit 分页，返回这一页和该标签的总数。
    func series(tag: String, offset: Int = 0, limit: Int = 24) -> (items: [Series], total: Int) {
        let lists = buildTagIndex()
        guard let ti = tagTable.firstIndex(of: tag), ti < lists.count else { return ([], 0) }
        let l = lists[ti]
        let total = l.count
        guard limit > 0, offset >= 0, offset < total else { return ([], total) }
        let end = min(offset + limit, total)
        var items: [Series] = []
        items.reserveCapacity(end - offset)
        for k in offset..<end {
            if let one = series(at: Int(l[k])) { items.append(one) }
        }
        return (items, total)
    }

    // MARK: - 搜索

    struct SearchResult {
        var list: [Series] = []
        /// 命中的**不同剧集**总数（列表只展示前 limit 条）
        var total = 0
    }

    /// 片名子串搜索，ASCII 大小写不敏感。
    func search(_ keyword: String, limit: Int = 300) -> SearchResult {
        load()
        var out = SearchResult()
        guard let d = data, count > 0, !keyword.isEmpty else { return out }
        let needle = Array(keyword.utf8)
        guard !needle.isEmpty, needle.count <= 64 else { return out }

        var hits: [Int] = []
        hits.reserveCapacity(min(limit, 128))
        var total = 0
        var last = -1
        d.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.advanced(by: titleBlobOff).assumingMemoryBound(to: UInt8.self) else { return }
            let n = titleBlobLen, m = needle.count
            guard n >= m else { return }
            var i = 0
            while i <= n - m {
                var k = 0
                while k < m {
                    let a = base[i + k], b = needle[k]
                    if a != b && Self.fold(a) != Self.fold(b) { break }
                    k += 1
                }
                if k == m {
                    if let idx = recordIndex(forByteOffset: i), idx != last {
                        last = idx
                        total += 1
                        if hits.count < limit { hits.append(idx) }
                    }
                    i += m
                } else {
                    i += 1
                }
            }
        }
        out.total = total
        out.list = hits.compactMap { series(at: $0) }
        return out
    }

    @inline(__always)
    private static func fold(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c &+ 32 : c }

    /// 片名 blob 里的字节位置 -> 记录下标
    private func recordIndex(forByteOffset offset: Int) -> Int? {
        guard let d = data else { return nil }
        var lo = 0, hi = count, result: Int? = nil
        d.withUnsafeBytes { p in
            while lo < hi {
                let mid = (lo + hi) / 2
                let s = Int(p.loadUnaligned(fromByteOffset: titleOffOff + mid * 4, as: UInt32.self))
                let e = Int(p.loadUnaligned(fromByteOffset: titleOffOff + (mid + 1) * 4, as: UInt32.self))
                if offset < s { hi = mid }
                else if offset >= e { lo = mid + 1 }
                else { result = mid; return }
            }
        }
        return result
    }
}