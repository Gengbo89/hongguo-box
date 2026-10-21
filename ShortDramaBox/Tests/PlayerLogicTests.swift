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
    // MARK: - 批量取流（1080p 主力线路）

    /// 请求体必须是 video_platform=1024 + mixed_video_id_map。
    /// 这是 2026-10-21 实测唯一能拿到高清的组合：别的 video_platform
    /// 服务端一律回 `video platform invalid`，而视频号放错字段名也一样。
    func testMultiBodyUsesPlatform1024AndMixedMap() {
        let b = PlayerAPI.multiBody("7694961195043785752")
        let bp = b["biz_param"] as? [String: Any] ?? [:]
        XCTAssertEqual(bp["video_platform"] as? Int, 1024, "video_platform 必须是 1024")
        XCTAssertEqual(bp["need_all_video_definition"] as? Bool, true, "必须要求全部档位")
        let map = b["mixed_video_id_map"] as? [String: [String]] ?? [:]
        XCTAssertEqual(map["1"], ["7694961195043785752"], "视频号要放在 mixed_video_id_map")
        XCTAssertNil(b["video_id_list"], "旧的 video_id_list 形态会被服务端拒答")
        XCTAssertNil(b["video_id"], "批量接口不带单数 video_id")
    }

    /// 批量接口路径不能写错（旧的单条接口现在一律 0 字节）
    func testMultiPathIsBatchEndpoint() {
        XCTAssertEqual(PlayerAPI.multiPath, "/novel/player/multi_video_model/v1/")
        XCTAssertNotEqual(PlayerAPI.multiPath, PlayerAPI.path)
    }

    // MARK: - 档位解析

    /// 真机返回的形态：video_model 是 JSON 字符串，档位元数据嵌在
    /// video_meta / encrypt_info 里（不是平铺在档位对象上）
    func testParseTracksReadsNestedMetaAndSpade() {
        let json = """
        {"status":10,"video_list":[
          {"main_url":"https://cdn.example/1080.mp4",
           "video_meta":{"definition":"1080p","vwidth":1080,"vheight":1920,
                         "size":6628394,"codec_type":"bytevc1"},
           "encrypt_info":{"encrypt":true,"spade_a":"lrwY9laPLPdVjhvAV4gcx1e8G8VnvBv2"}},
          {"main_url":"https://cdn.example/360.mp4",
           "video_meta":{"definition":"360p","vwidth":360,"vheight":640,
                         "size":2260149,"codec_type":"bytevc1"},
           "encrypt_info":{"spade_a":"AAAA"}}
        ]}
        """
        let list = PlayerAPI.parseTracks(json)
        XCTAssertEqual(list.count, 2, "两条档位都要解析出来")
        XCTAssertEqual(list.first?.definition, "1080p")
        XCTAssertEqual(list.first?.width, 1080)
        XCTAssertEqual(list.first?.height, 1920)
        XCTAssertEqual(list.first?.size, 6628394)
        XCTAssertEqual(list.first?.codec, "bytevc1")
        XCTAssertEqual(list.first?.spadeA, "lrwY9laPLPdVjhvAV4gcx1e8G8VnvBv2")
        XCTAssertTrue(PlayerAPI.isPlayableCodec(list.first?.codec ?? ""), "bytevc1 应能直接播")
        XCTAssertFalse(PlayerAPI.needsTranscode(list[0]), "bytevc1 不需要本机转码")
    }

    /// 没有直链的档位不能出现在列表里（否则用户选到就是黑屏）
    func testParseTracksDropsTracksWithoutURL() {
        let json = """
        {"video_list":[
          {"video_meta":{"definition":"1080p","vwidth":1080,"vheight":1920},
           "encrypt_info":{"spade_a":"AAAA"}},
          {"main_url":"https://cdn.example/360.mp4",
           "video_meta":{"definition":"360p","vwidth":360,"vheight":640},
           "encrypt_info":{"spade_a":"AAAA"}}
        ]}
        """
        let list = PlayerAPI.parseTracks(json)
        XCTAssertEqual(list.count, 1, "没直链的那条要被丢掉")
        XCTAssertEqual(list.first?.definition, "360p")
    }

    /// 空字典 / 畸形输入不能崩，返回空列表
    func testParseTracksHandlesGarbage() {
        XCTAssertTrue(PlayerAPI.parseTracks([String: Any]()).isEmpty)
        XCTAssertTrue(PlayerAPI.parseTracks("{}").isEmpty)
        XCTAssertTrue(PlayerAPI.parseTracks("不是JSON").isEmpty)
        XCTAssertTrue(PlayerAPI.parseTracks("").isEmpty)
    }

    // MARK: - 直链解码

    /// 直链有时是明文 https，有时是 base64（桌面版两种都遇到过）
    func testMediaURLHandlesPlainAndBase64() {
        let plain = "https://v95.example/1080.mp4"
        XCTAssertEqual(PlayerAPI.mediaURL(["main_url": plain]), plain)

        let enc = Data(plain.utf8).base64EncodedString()
        XCTAssertEqual(PlayerAPI.mediaURL(["main_url": enc]), plain, "base64 直链要解出来")

        XCTAssertEqual(PlayerAPI.mediaURL([:]), "")
        XCTAssertEqual(PlayerAPI.mediaURL(["main_url": "%%%"]), "")
    }

    /// main_url 不在时退回 backup_url
    func testMediaURLFallsBackToBackup() {
        let backup = "https://backup.example/720.mp4"
        XCTAssertEqual(PlayerAPI.mediaURL(["main_url": "", "backup_url": backup]), backup)
    }
}
