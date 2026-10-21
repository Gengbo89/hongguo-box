import Foundation

/// MP4 盒遍历与样本定位（移植自 decutil.py / oracle.py）
struct Box { let type: String; let start: Int; let end: Int; let hdr: Int }

func be32(_ d: [UInt8], _ o: Int) -> Int {
    guard o + 4 <= d.count else { return 0 }
    return (Int(d[o]) << 24) | (Int(d[o+1]) << 16) | (Int(d[o+2]) << 8) | Int(d[o+3])
}
func be64(_ d: [UInt8], _ o: Int) -> Int {
    guard o + 8 <= d.count else { return 0 }
    return (be32(d, o) << 32) | be32(d, o + 4)
}
func be64u(_ d: [UInt8], _ o: Int) -> UInt64 {
    guard o + 8 <= d.count else { return 0 }
    return (UInt64(be32(d, o)) << 32) | UInt64(be32(d, o + 4))
}
func fourCC(_ d: [UInt8], _ o: Int) -> String {
    guard o + 4 <= d.count else { return "" }
    return String(bytes: d[o..<(o+4)], encoding: .isoLatin1) ?? ""
}
/// 遍历 [s,e) 内的同级盒
func boxes(_ d: [UInt8], _ s: Int, _ e: Int) -> [Box] {
    var out: [Box] = []; var o = s
    while o + 8 <= e {
        var sz = be32(d, o); let t = fourCC(d, o + 4); var hs = 8
        if sz == 1 { sz = be64(d, o + 8); hs = 16 }
        else if sz == 0 { sz = e - o }
        if sz < hs || o + sz > e { break }
        out.append(Box(type: t, start: o, end: o + sz, hdr: hs))
        o += sz
    }
    return out
}
/// 按路径查找，返回内容区 (start,end)
func findBox(_ d: [UInt8], _ path: [String], _ s: Int, _ e: Int) -> (Int, Int)? {
    guard let first = path.first else { return (s, e) }
    for b in boxes(d, s, e) where b.type == first {
        if path.count == 1 { return (b.start + b.hdr, b.end) }
        if let r = findBox(d, Array(path.dropFirst()), b.start + b.hdr, b.end) { return r }
    }
    return nil
}

/// 样本数上限：正常一集 1080p 也就几千个样本，给到 400 万足够，
/// 主要用来挡住损坏文件里的天文数字（防分配爆炸）
let maxSamples = 4_000_000

/// 解析指定 handler 轨（vide/soun）的样本 (sizes, offs)
func parseTrackSamples(_ d: [UInt8], handler: String) -> ([Int], [Int]) {
    guard let mv = findBox(d, ["moov"], 0, d.count) else { return ([], []) }
    let traks = boxes(d, mv.0, mv.1).filter { $0.type == "trak" }
    func hdlr(_ b: Box) -> String? {
        guard let h = findBox(d, ["mdia", "hdlr"], b.start + b.hdr, b.end) else { return nil }
        return fourCC(d, h.0 + 8)
    }
    guard let want = traks.first(where: { hdlr($0) == handler }) else { return ([], []) }
    guard let stbl = findBox(d, ["mdia", "minf", "stbl"], want.start + want.hdr, want.end) else { return ([], []) }
    guard let stsz = findBox(d, ["stsz"], stbl.0, stbl.1),
          let stsc = findBox(d, ["stsc"], stbl.0, stbl.1) else { return ([], []) }
    let ss = be32(d, stsz.0 + 4), cnt = be32(d, stsz.0 + 8)
    // 样本数来自文件本身：损坏/截断文件里可能是任意 32 位数，
    // 直接拿去 [Int](repeating:count:) 会当场分配几十 GB 被系统杀掉。
    guard cnt >= 0, cnt <= maxSamples else { return ([], []) }
    var sizes = [Int]()
    if ss != 0 { sizes = [Int](repeating: ss, count: cnt) }
    else { for i in 0..<cnt { sizes.append(be32(d, stsz.0 + 12 + 4 * i)) } }
    var ch = [Int]()
    if let stco = findBox(d, ["stco"], stbl.0, stbl.1) {
        let n = be32(d, stco.0 + 4)
        guard n >= 0, n <= maxSamples else { return ([], []) }
        for i in 0..<n { ch.append(be32(d, stco.0 + 8 + 4 * i)) }
    } else if let co64 = findBox(d, ["co64"], stbl.0, stbl.1) {
        let n = be32(d, co64.0 + 4)
        guard n >= 0, n <= maxSamples else { return ([], []) }
        for i in 0..<n { ch.append(be64(d, co64.0 + 8 + 8 * i)) }
    }
    let ne = be32(d, stsc.0 + 4)
    guard ne >= 0, ne <= maxSamples else { return ([], []) }
    var runs = [(Int, Int, Int)]()
    for i in 0..<ne { runs.append((be32(d, stsc.0 + 8 + 12*i), be32(d, stsc.0 + 12 + 12*i), be32(d, stsc.0 + 16 + 12*i))) }
    var spc = [Int](repeating: 0, count: ch.count)
    for (i, r) in runs.enumerated() {
        let last = i + 1 < runs.count ? runs[i+1].0 - 1 : ch.count
        if last >= r.0 { for c in r.0...last where c >= 1 && c <= ch.count { spc[c-1] = r.1 } }
    }
    var offs = [Int](); var si = 0
    for c in 0..<ch.count {
        var off = ch[c]
        for _ in 0..<spc[c] {
            if si >= cnt { break }
            offs.append(off); off += sizes[si]; si += 1
        }
    }
    return (sizes, offs)
}

import CommonCrypto

/// 在 trak 范围内找 senc 盒，返回首样本 base_iv 高 8 字节
func sencIV8(_ d: [UInt8], _ lo: Int, _ hi: Int) -> UInt64? {
    var i = lo
    let top = min(hi, d.count)
    while i + 20 <= top {
        if d[i] == 0x73 && d[i+1] == 0x65 && d[i+2] == 0x6e && d[i+3] == 0x63 {
            return be64u(d, i + 12)
        }
        i += 1
    }
    return nil
}
func tencKID(_ d: [UInt8], _ lo: Int, _ hi: Int) -> String? {
    for b in boxes(d, lo, hi) where b.type == "tenc" {
        let o = b.start + b.hdr
        if o + 20 <= d.count { return (o+4..<o+20).map { String(format: "%02x", d[$0]) }.joined() }
    }
    return nil
}
/// 样本是否为合法的长度前缀 NAL 序列（自证解密正确）
func nalOK(_ s: ArraySlice<UInt8>) -> Bool {
    let d = Array(s); var p = 0
    while p + 4 <= d.count {
        let ln = be32(d, p)
        if ln == 0 || p + 4 + ln > d.count { return false }
        p += 4 + ln
    }
    return p == d.count
}
/// AES-128-CTR 解密；计数器初值 = ((baseIV + idx) << 64)
func aesCTR(_ key: [UInt8], _ iv: [UInt8], _ input: ArraySlice<UInt8>) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: input.count)
    var cryptor: CCCryptorRef?
    var ivm = iv
    let st = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR),
        CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), &ivm,
        key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
    guard st == kCCSuccess, let c = cryptor else { return out }
    let inp = Array(input)
    let n = inp.count
    var moved = 0
    var r = Int32(kCCSuccess)
    inp.withUnsafeBytes { ip in
        out.withUnsafeMutableBytes { op in
            r = CCCryptorUpdate(c, ip.baseAddress, n, op.baseAddress, n, &moved)
        }
    }
    CCCryptorRelease(c)
    return r == kCCSuccess ? out : [UInt8](repeating: 0, count: input.count)
}

/// 十六进制字符串 -> 字节。长度奇数、或含非 hex 字符一律返回 nil。
///
/// 原来是 `UInt8(h[i..<j], radix: 16)!` 强解包 + 无长度检查：
/// spade_a 解出来的 key 只要有一个非 hex 字符就崩在强解包上，
/// 长度为奇数则 `index(i, offsetBy: 2)` 直接越过 endIndex 崩在字符串下标上。
/// 这条路径在 1080p 修好之后每次播放/每次后台预取都会走 —— 闪退高发点之一。
func hexBytes(_ h: String) -> [UInt8]? {
    guard !h.isEmpty, h.count % 2 == 0 else { return nil }
    var o = [UInt8](); o.reserveCapacity(h.count / 2)
    var i = h.startIndex
    while i < h.endIndex {
        let j = h.index(i, offsetBy: 2)
        guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
        o.append(b); i = j
    }
    return o
}
/// 解密全部加密轨（视频+音频），每轨用自身 senc base_iv
///
/// 返回每轨 (自证成功的样本数, 样本总数)，失败返回空字典。
/// 另外会在 `skipped` 里报告「偏移越界被跳过」的样本数，方便定位坏文件。
func decryptAV(_ path: String, keyHex: String, outPath: String) -> [String: (Int, Int)] {
    guard var buf = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: path))) else { return [:] }
    // key 必须是 16 字节；长度不对就别往下走（CCCryptor 会直接失败，白跑一趟）
    guard let K = hexBytes(keyHex), K.count == 16 else { return [:] }
    guard let mv = findBox(buf, ["moov"], 0, buf.count) else { return [:] }
    var stats = [String: (Int, Int)]()
    var skipped = 0
    for tr in boxes(buf, mv.0, mv.1) where tr.type == "trak" {
        guard let h = findBox(buf, ["mdia", "hdlr"], tr.start + tr.hdr, tr.end) else { continue }
        let handler = fourCC(buf, h.0 + 8)
        if handler != "vide" && handler != "soun" { continue }
        guard let biv = sencIV8(buf, tr.start, tr.end) else { continue }
        let (sizes, offs) = parseTrackSamples(buf, handler: handler)
        if sizes.isEmpty { continue }
        for (idx, o) in offs.enumerated() {
            guard idx < sizes.count else { break }
            let sz = sizes[idx]
            // 关键：o/sz 全部来自文件里的 stco/stsz。下载被截断、或文件本身异常时，
            // o+sz 会越过 buf 末尾 —— 原来这一行没有边界检查，越界当场 SIGABRT（闪退）。
            // 现在越界的样本直接跳过，只解能解的那部分。
            guard sz > 0, o >= 0, o <= buf.count, sz <= buf.count - o else { skipped += 1; continue }
            let ctr = biv &+ UInt64(idx)
            var iv = [UInt8](repeating: 0, count: 16)
            for k in 0..<8 { iv[k] = UInt8((ctr >> UInt64(56 - 8*k)) & 0xff) }
            buf[o..<(o+sz)] = ArraySlice(aesCTR(K, iv, buf[o..<(o+sz)]))
        }
        if handler == "vide" {
            let ok = zip(offs, sizes).filter { $0.0 >= 0 && $0.1 > 0 && $0.0 + $0.1 <= buf.count
                && nalOK(buf[$0.0..<($0.0+$0.1)]) }.count
            stats["vide"] = (ok, sizes.count)
        } else { stats["soun"] = (0, sizes.count) }
    }
    if skipped > 0 { stats["skipped"] = (skipped, 0) }
    try? Data(buf).write(to: URL(fileURLWithPath: outPath))
    return stats
}

func be32b(_ v: Int) -> [UInt8] {
    [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
}
func makeBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    be32b(8 + payload.count) + Array(type.utf8) + payload
}
let containers: Set<String> = ["moov","trak","mdia","minf","stbl","edts","dinf","udta",
                               "mvex","moof","traf","mfra","skip","meta","ilst"]
let sampleEntryFixed: [String: Int] = ["encv": 78, "hvc1": 78, "hev1": 78, "avc1": 78,
                                       "enca": 28, "mp4a": 28]
let dropBoxes: Set<String> = ["senc", "saiz", "saio"]

/// 重写样本条目：encv/enca -> frma 指定的原始格式，并丢弃 sinf
func rewriteSampleEntry(_ d: [UInt8], _ b: Box) -> [UInt8] {
    let fixed = sampleEntryFixed[b.type] ?? 78
    let childStart = b.start + 8 + fixed
    var frma: String? = nil
    if childStart < b.end {
        for c in boxes(d, childStart, b.end) where c.type == "sinf" {
            for g in boxes(d, c.start + c.hdr, c.end) where g.type == "frma" {
                frma = fourCC(d, g.start + g.hdr)
            }
        }
    }
    let newType = frma ?? b.type
    var rest = Array(d[(b.start + 8)..<min(childStart, b.end)])
    if childStart < b.end {
        for c in boxes(d, childStart, b.end) where c.type != "sinf" {
            rest += Array(d[c.start..<c.end])
        }
    }
    return makeBox(newType, rest)
}
