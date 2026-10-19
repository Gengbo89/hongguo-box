import Foundation

func popcount(_ x: Int) -> Int { Int(UInt32(truncatingIfNeeded: x).nonzeroBitCount) }
func s8(_ v: Int) -> Int { let b = v & 0xff; return b >= 128 ? b - 256 : b }

/// 红果 spade_a -> content key。移植自 unwrap_spade.py（逆向 libttmplayer.so FUN_001c4550）
func unwrapV1(_ spade: [UInt8], flag: Int = 0) -> String? {
    let L = spade.count
    if L < 3 { return nil }
    let bVar5 = Int(spade[0] ^ spade[1] ^ spade[2])
    let iVar9 = bVar5 - 0x30
    if iVar9 < 1 { return nil }
    let uVar1 = (L - bVar5) + 0x2f
    if uVar1 < 1 || 1 + uVar1 > L { return nil }
    var dest = Array(spade[1..<(1 + uVar1)])

    var s1 = [UInt8](repeating: 0, count: iVar9)
    let bt16 = spade[L - iVar9 - 2], bt14 = spade[L - iVar9 - 1]
    for i in 0..<iVar9 { s1[i] = bt14 ^ bt16 ^ spade[i + (L - iVar9)] }
    func eq(_ a: [UInt8], _ s: String, _ n: Int) -> Bool {
        let b = Array(s.utf8)
        for k in 0..<n {
            let ca = k < a.count ? a[k] : 0, cb = k < b.count ? b[k] : 0
            if ca != cb { return false }
            if ca == 0 { return true }
        }
        return true
    }
    if eq(s1, "app_v2", iVar9) || eq(s1, "web_v2", iVar9) { return nil }

    var b14: UInt8 = 0x55, b16: UInt8 = 0xfa
    for i in 0..<uVar1 {
        let b6 = dest[i]
        let u18 = popcount(i)
        var b3 = b6, b7 = b14
        if i & 1 == 1 { b3 = b16; b7 = b6; b16 = b14 }
        let cVar4 = flag != 0 ? (u18 + 0x15) : s8(-0x15 - u18)
        dest[i] = UInt8(truncatingIfNeeded: cVar4 + Int(b16 ^ b6))
        b14 = b7; b16 = b3
    }
    let b0 = dest[0]
    var u11: Int
    if b0 >= 0x30 && b0 <= 0x39 { u11 = Int(b0 - 0x30) }
    else if b0 >= 0x61 && b0 <= 0x7a { u11 = Int(b0 - 0x57) }
    else { return nil }
    let iv9 = uVar1 - (u11 & 0xff)
    if iv9 < 2 { return nil }
    return String(bytes: dest[1..<iv9], encoding: .isoLatin1)
}

func spadeToKey(_ b64: String, flag: Int = 0) -> String? {
    guard let d = Data(base64Encoded: b64) else { return nil }
    return unwrapV1([UInt8](d), flag: flag)
}
