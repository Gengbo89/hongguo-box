import Foundation
/// 递归重写盒子；返回 nil 表示丢弃
func rewriteBox(_ d: [UInt8], _ b: Box) -> [UInt8]? {
    if dropBoxes.contains(b.type) { return nil }
    let cs = b.start + b.hdr
    if sampleEntryFixed[b.type] != nil { return rewriteSampleEntry(d, b) }
    if b.type == "stsd" {
        let head = Array(d[cs..<min(cs + 8, b.end)])
        var entries: [UInt8] = []; var n = 0
        if cs + 8 <= b.end {
            for e in boxes(d, cs + 8, b.end) {
                entries += rewriteSampleEntry(d, e); n += 1
            }
        }
        var payload = head
        if payload.count >= 8 { payload[4] = UInt8((n >> 24) & 0xff); payload[5] = UInt8((n >> 16) & 0xff)
                               payload[6] = UInt8((n >> 8) & 0xff);  payload[7] = UInt8(n & 0xff) }
        return makeBox(b.type, payload + entries)
    }
    if containers.contains(b.type) {
        var kids: [UInt8] = []
        for c in boxes(d, cs, b.end) { if let r = rewriteBox(d, c) { kids += r } }
        return makeBox(b.type, kids)
    }
    return Array(d[b.start..<b.end])
}

/// 剥离 CENC 信令，并用 free 盒补齐使 mdat 绝对偏移不变（stco 无需重算）
func stripCENC(_ path: String, outPath: String) -> Int {
    guard let d = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: path))) else { return -1 }
    guard let mv = boxes(d, 0, d.count).first(where: { $0.type == "moov" }) else { return -1 }
    var newMoov: [UInt8] = []
    for c in boxes(d, mv.start + mv.hdr, mv.end) { if let r = rewriteBox(d, c) { newMoov += r } }
    let rebuilt = makeBox("moov", newMoov)
    let delta = (mv.end - mv.start) - rebuilt.count
    var out = Array(d[0..<mv.start]) + rebuilt
    if delta >= 8 { out += makeBox("free", [UInt8](repeating: 0, count: delta - 8)) }
    else if delta > 0 { out += [UInt8](repeating: 0, count: delta) }
    out += Array(d[mv.end..<d.count])
    try? Data(out).write(to: URL(fileURLWithPath: outPath))
    return delta
}
