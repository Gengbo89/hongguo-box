import XCTest
@testable import ShortDramaBox

/// 取流/档位选择逻辑。这几条一旦错，用户看到的就是「黑屏」「没有片源」
/// 「清晰度乱跳」，而且不看日志根本不知道错在哪，所以全部钉死。
final class PlayerLogicTests: XCTestCase {

    private func track(_ codec: String, _ w: Int, _ h: Int, _ size: Int,
                       spade: String = "abcd") -> VideoTrack {
        var t = VideoTrack()
        t.codec = codec; t.width = w; t.height = h; t.size = size; t.spadeA = spade
        t.url = "https://example.invalid/\(codec)-\(w).mp4"
        return t
    }

    // MARK: - 解码能力判定

    func testH264AndH265ArePlayable() {
        for c in ["avc1", "avc3", "hvc1", "hev1", "h265", "hevc", "bytevc1"] {
            XCTAssertTrue(PlayerAPI.isPlayableCodec(c), "\(c) 应该能直接播")
        }
    }

    func testBytevc2AndOthersNeedTranscode() {
        // bvc2 是字节自研私有编码，VideoToolbox 返回 -12906，直接播必然黑屏
        for c in ["bytevc2", "bvc2", "vp09", "vcv1", "av01"] {
            XCTAssertFalse(PlayerAPI.isPlayableCodec(c), "\(c) 不该被当成能直接播")
        }
    }

    func testCodecCheckIsCaseInsensitive() {
        XCTAssertTrue(PlayerAPI.isPlayableCodec("AVC1"))
        XCTAssertTrue(PlayerAPI.isPlayableCodec("ByteVC1"))
    }

    /// 编码未知时不能武断排除（否则会把能播的源当成不能播）
    func testUnknownCodecIsNotExcluded() {
        XCTAssertTrue(PlayerAPI.isPlayableCodec(""))
    }

    // MARK: - 是否需要本机转码

    func testPublicFallbackNeverNeedsTranscode() {
        // 公开 360p 是明文 H.264，没有 spade_a
        let t = track("avc1", 360, 640, 1000, spade: "")
        XCTAssertFalse(PlayerAPI.needsTranscode(t))
    }

    func testPlayableEncryptedTrackNeedsNoTranscode() {
        XCTAssertFalse(PlayerAPI.needsTranscode(track("bytevc1", 1080, 1920, 9_000_000)))
    }

    func testBytevc2EncryptedTrackNeedsTranscode() {
        XCTAssertTrue(PlayerAPI.needsTranscode(track("bytevc2", 360, 640, 500_000)))
    }

    // MARK: - 排序（先比短边，再比体量）

    func testSortedByShortEdgeThenSize() {
        let list = [
            track("avc1", 640, 360, 400_000),
            track("avc1", 1920, 1080, 5_000_000),
            track("avc1", 1280, 720, 2_000_000),
            track("avc1", 1080, 1920, 9_000_000),
        ]
        let s = PlayerAPI.sorted(list)
        XCTAssertEqual(s.map { min($0.width, $0.height) }, [1080, 1080, 720, 360])
        XCTAssertEqual(s[0].size, 9_000_000, "同短边时体量大的应该在前")
    }

    /// 竖屏短剧 width<height，短边必须取 min 而不是直接取 width
    func testShortEdgeUsesMinNotWidth() {
        let portrait = track("avc1", 720, 1280, 1)
        let landscape = track("avc1", 1280, 720, 1)
        let s = PlayerAPI.sorted([portrait, landscape])
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(min(s[0].width, s[0].height), 720)
    }

    // MARK: - 可播子集 / 转码源

    func testPlayableFiltersOutBytevc2() {
        let list = [track("bytevc2", 360, 640, 1), track("bytevc1", 1080, 1920, 2)]
        let p = PlayerAPI.playable(list)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].codec, "bytevc1")
    }

    func testTranscodeSourcePicksHighestPlayable() {
        let list = [
            track("bytevc2", 1080, 1920, 9_000_000),
            track("bytevc1", 720, 1280, 3_000_000),
            track("hvc1", 540, 960, 1_500_000),
        ]
        let src = PlayerAPI.transcodeSource(list)
        XCTAssertEqual(src?.codec, "bytevc1")
        XCTAssertEqual(min(src?.width ?? 0, src?.height ?? 0), 720)
    }

    func testTranscodeSourceNilWhenNothingPlayable() {
        XCTAssertNil(PlayerAPI.transcodeSource([track("bytevc2", 1080, 1920, 1)]))
    }

    // MARK: - 转码档位映射

    /// 「不超过给定短边、且最接近」—— 转码目标档位就靠它，选错会白转或更糊
    func testRenditionNearestAtMost() {
        XCTAssertEqual(Rendition.nearest(atMost: 2000), .p1080)
        XCTAssertEqual(Rendition.nearest(atMost: 1080), .p1080)
        XCTAssertEqual(Rendition.nearest(atMost: 1079), .p720)
        XCTAssertEqual(Rendition.nearest(atMost: 720), .p720)
        XCTAssertEqual(Rendition.nearest(atMost: 719), .p540)
        XCTAssertEqual(Rendition.nearest(atMost: 600), .p540)
        XCTAssertEqual(Rendition.nearest(atMost: 539), .p480)
        XCTAssertEqual(Rendition.nearest(atMost: 479), .p360)
        XCTAssertEqual(Rendition.nearest(atMost: 360), .p360)
        // 比最低档还低：没有合适档位，不能硬塞一个更高的档
        XCTAssertNil(Rendition.nearest(atMost: 359))
        XCTAssertNil(Rendition.nearest(atMost: 100))
    }

    func testRenditionMatchingExactShortEdge() {
        XCTAssertEqual(Rendition.matching(shortEdge: 1080), .p1080)
        XCTAssertEqual(Rendition.matching(shortEdge: 360), .p360)
        XCTAssertNil(Rendition.matching(shortEdge: 999))
    }

    /// 码率必须随清晰度单调递减，否则「转码后更小」这个前提不成立
    func testRenditionBitrateIsMonotonic() {
        let b = Rendition.allCases.map { $0.videoBitrate }
        XCTAssertEqual(b, b.sorted(by: >), "档位码率不是从高到低：\(b)")
        let e = Rendition.allCases.map { $0.shortEdge }
        XCTAssertEqual(e, e.sorted(by: >), "档位短边不是从高到低：\(e)")
    }

    // MARK: - 取流降级（2026-10-21 服务端对第三方客户端静默拒答后新增）

    /// 多套 profile 必须真的存在，且顺序固定（主线路优先）
    func testProfileOrderIsStable() {
        XCTAssertEqual(PlayerAPI.profiles.map { $0.name }, ["app-b", "app-c", "audit-a"])
        XCTAssertTrue(PlayerAPI.profiles.allSatisfy { $0.host.hasPrefix("https://") })
        XCTAssertTrue(PlayerAPI.profiles.allSatisfy { !$0.query.isEmpty })
    }

    /// 公网候选必须从高到低，最高 1080p，最低 360p
    func testPublicQualitiesAreDescending() {
        let e = PlayerAPI.publicQualities.map { min($0.1, $0.2) }
        XCTAssertEqual(e, e.sorted(by: >), "公网候选档位没有从高到低排")
        XCTAssertEqual(PlayerAPI.publicQualities.first?.0, "1080p")
        XCTAssertEqual(PlayerAPI.publicQualities.last?.0, "360p")
    }

    /// 相同失败原因合并计数，顺序按首次出现
    func testReasonSummaryMergesDuplicates() {
        XCTAssertEqual(PlayerAPI.reasonSummary(["200/0字节", "200/0字节", "code100001"]),
                       "200/0字节×2、code100001")
    }

    /// 只出现一次不加计数后缀；空列表给空串
    func testReasonSummarySingleReasonHasNoCount() {
        XCTAssertEqual(PlayerAPI.reasonSummary(["网络失败"]), "网络失败")
        XCTAssertEqual(PlayerAPI.reasonSummary([]), "")
    }

    /// 档位默认没有降级说明；有说明的档位排序后说明不能丢
    func testNoteDefaultsEmptyAndSurvivesSorting() {
        XCTAssertEqual(VideoTrack().note, "")
        var low = track("avc1", 360, 640, 100, spade: "")
        low.note = "高清接口无档位(200/0字节×3)"
        let high = track("bytevc1", 1080, 1920, 900)
        let out = PlayerAPI.sorted([low, high])
        XCTAssertEqual(out.first?.width, 1080, "1080p 应该排在前面")
        XCTAssertEqual(out.last?.note, "高清接口无档位(200/0字节×3)", "降级说明被排序丢掉了")
    }
}