import XCTest
@testable import ShortDramaBox

/// 坏文件解析加固：大数不能再触发 Swift 整数溢出 trap。
///
/// 为什么专门测这个：1080p 每一档都带 spade_a + cenc-aes-ctr，也就是**每集播放
/// 都要走一遍 MP4 盒解析 + 解密**。盒子长度、co64 偏移这些字段全部来自文件本身，
/// 下载被截断或文件异常时可能是任意 64 位数；`be32(...) << 32` 一旦超过 Int64
/// 上限，Swift 的有符号溢出会**直接 trap 把进程带走**——用户看到的就是闪退。
final class OverflowTests: XCTestCase {

    func testBe64HugeValueClampsInsteadOfTrapping() {
        let allFF: [UInt8] = [0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF]
        XCTAssertEqual(be64(allFF, 0), Int.max, "天文长度必须夹住，不能 trap")
        XCTAssertEqual(be64u(allFF, 0), UInt64.max, "无符号版本不受影响")
    }

    func testBe64NormalAndShortBuffer() {
        XCTAssertEqual(be64([0,0,0,0, 0,0,0,42], 0), 42)
        XCTAssertEqual(be64([1,2,3], 0), 0, "长度不够返回 0")
    }

    func testBe64ChunkOffsetStyleValue() {
        // co64 里 0x00000001_00000000 这种偏移是合法的，不能被夹错
        XCTAssertEqual(be64([0,0,0,1, 0,0,0,0], 0), 4_294_967_296)
    }

    func testBoxesDropsHuge64BitSizeWithoutTrapping() {
        var d: [UInt8] = [0,0,0,1]                        // size == 1 → 读 64 位长度
        d += Array("moov".utf8)
        d += [0xFF,0xFF,0xFF,0xFF, 0xFF,0xFF,0xFF,0xFF]   // 天文长度
        d += [UInt8](repeating: 0, count: 16)
        XCTAssertTrue(boxes(d, 0, d.count).isEmpty, "超大盒子必须被丢掉，而不是把进程带走")
    }

    func testBoxesStillParsesNormalBoxes() {
        var d: [UInt8] = [0,0,0,8] + Array("free".utf8)     // 空 free 盒
        d += [0,0,0,16] + Array("moov".utf8) + [0,0,0,0]    // 16 字节 moov
        let bs = boxes(d, 0, d.count)
        XCTAssertEqual(bs.map(\.type), ["free", "moov"])
        XCTAssertEqual(bs[0].hdr, 8)
        XCTAssertEqual(bs[1].end, d.count)
    }

    func testZeroSizeBoxTakesRest() {
        let d: [UInt8] = [0,0,0,0] + Array("mdat".utf8) + [1,2,3,4]
        let bs = boxes(d, 0, d.count)
        XCTAssertEqual(bs.count, 1)
        XCTAssertEqual(bs[0].end, d.count, "size==0 表示一直到末尾")
    }

    func testTruncatedBoxDoesNotCrash() {
        // 声明 100 字节但只给了 12 字节：必须停下来而不是越界
        let d: [UInt8] = [0,0,0,100] + Array("mdat".utf8)
        XCTAssertTrue(boxes(d, 0, d.count).isEmpty)
    }
}