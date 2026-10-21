import Foundation

/// 游客身份取流：无需签名 / 登录 / Cookie（逆向自桌面版后端）
///
/// ⚠️ 2026-10-21 实测：官方取流接口对第三方客户端**静默拒答**：
///    POST /novel/player/video_model/v1/ 一律返回 `HTTP 200 + 0 字节`，
///    与请求体、请求头、host、出口 IP 均无关：
///    · 两个完全不同的出口 IP（家宽 111.4.83.x / 阿里云杭州 112.124.63.35）结果一致
///    · 当年实测可用的原始脚本原样重跑，同样 0 字节
///    · 带/不带 x-ss-stub（MD5(body)）结果一致 —— 该签名已不被接受
///    · 桌面版（原项目）依赖外部签名服务 / Frida 预言机取真签名，
///      说明服务端已要求真正的 App 签名（x-gorgon/x-argus 一系）
///    所以这里**依次尝试多套 profile**（多 host / 多 UA / 多参数组合），
///    任何一套通了就立刻用高清；全都不通时回退公网明文，
///    并把「为什么没有高清」写进 `VideoTrack.note` 让界面显示 —— 绝不静默变糊。
enum PlayerAPI {
    // MARK: - 请求 profile

    /// 一套完整的取流请求特征（host + 查询串 + 请求头）
    struct Profile {
        let name: String
        let host: String
        let query: [(String, String)]
        let headers: [(String, String)]
    }

    static let path = "/novel/player/video_model/v1/"

    /// 安卓 App 请求参数（逆向自 7.3.5.32 客户端）
    static let appQuery: [(String, String)] = [
        ("aid", "8662"), ("app_name", "novelread"), ("version_code", "73532"),
        ("version_name", "7.3.5.32"), ("manifest_version_code", "73532"),
        ("update_version_code", "73532"), ("channel", "update_64"),
        ("device_platform", "android"), ("os", "android"), ("ssmix", "a"),
        ("device_type", "25053RT47C"), ("device_brand", "Redmi"), ("language", "zh"),
        ("os_api", "36"), ("os_version", "16"), ("resolution", "1280*2772"),
        ("dpi", "520"), ("ac", "wifi"),
    ]

    static let ua = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; "
        + "Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 "
        + "QuicVersion:c67e9834 2025-09-08)"

    static let appHeaders: [(String, String)] = [
        ("user-agent", ua), ("accept", "application/json"),
        ("x-xs-from-web", "0"), ("sdk-version", "2"),
        ("content-type", "application/json; charset=utf-8"),
    ]

    /// 桌面版内置的「公开游客」profile（channel=audit / audit-windows）：
    /// 主机是 **a** 而不是 b，UA 是 hongguo-route-audit/1.0，另带区域头。
    static let auditQuery: [(String, String)] = [
        ("aid", "8662"), ("app_name", "novelread"), ("version_code", "72232"),
        ("version_name", "7.2.2.32"), ("channel", "audit"),
        ("device_platform", "android"), ("device_type", "audit-windows"),
        ("os_version", "12"), ("update_version_code", "72232"),
    ]

    static let auditHeaders: [(String, String)] = [
        ("user-agent", "hongguo-route-audit/1.0"), ("accept", "application/json"),
        ("x-tt-store-region", "cn-sh"), ("x-tt-store-region-src", "uid"),
        ("passport-sdk-version", "5051452"), ("sdk-version", "2"),
        ("content-type", "application/json; charset=utf-8"),
    ]

    /// 依次尝试顺序：主 App 线路 → 备用 host → 公开游客线路
    static let profiles: [Profile] = [
        Profile(name: "app-b", host: "https://api5-normal-sinfonlineb.fqnovel.com",
                query: appQuery, headers: appHeaders),
        Profile(name: "app-c", host: "https://api5-normal-sinfonlinec.fqnovel.com",
                query: appQuery, headers: appHeaders),
        Profile(name: "audit-a", host: "https://api5-normal-sinfonlinea.fqnovel.com",
                query: auditQuery, headers: auditHeaders),
    ]

    /// 随机游客设备号（持久化，避免每次变化）
    static var guestDevice: (id: String, iid: String) {
        let d = UserDefaults.standard
        if let a = d.string(forKey: "guest_device"), let b = d.string(forKey: "guest_iid") {
            return (a, b)
        }
        func rnd() -> String { String(UInt64.random(in: 1_000_000_000_000_000_000...9_999_999_999_999_999_999)) }
        let a = rnd(), b = rnd()
        d.set(a, forKey: "guest_device"); d.set(b, forKey: "guest_iid")
        return (a, b)
    }

    // MARK: - 单次请求

    /// 请求体（官方客户端固定这份结构）
    static func body(_ vid: String) -> [String: Any] {
        ["video_id": vid, "content_type": 1,
         "biz_param": ["need_all_video_definition": true, "video_platform": 3]]
    }

    /// 用某一套 profile 取一次档位。
    /// 失败时返回**简短原因**（给用户看的）：`200/0字节`、`HTTP404`、`code100001`…
    static func attempt(_ p: Profile, vid: String) async -> Result<[VideoTrack], FetchError> {
        let g = guestDevice
        let q = p.query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
            + "&device_id=\(g.id)&iid=\(g.iid)"
        guard let u = URL(string: p.host + path + "?" + q) else {
            return .failure(FetchError("URL非法"))
        }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        for h in p.headers { r.setValue(h.1, forHTTPHeaderField: h.0) }
        guard let raw = try? JSONSerialization.data(withJSONObject: body(vid)) else {
            return .failure(FetchError("请求体非法"))
        }
        r.httpBody = raw
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else {
            return .failure(FetchError("网络失败"))
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { return .failure(FetchError("HTTP\(status)")) }
        // 空体 / 非 JSON：服务端风控拒答的典型形态
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(FetchError("\(status)/\(data.count)字节"))
        }
        let code = asInt(root["code"])
        if code != 0 { return .failure(FetchError("code\(code)")) }
        guard let inner = asStr(asDict(root["data"])["video_model"]).data(using: .utf8),
              let vm = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any]
        else { return .failure(FetchError("无video_model")) }
        let list = asArr(vm["video_list"]).map { raw -> VideoTrack in
            let it = asDict(raw), m = asDict(it["video_meta"]), e = asDict(it["encrypt_info"])
            var t = VideoTrack()
            t.definition = asStr(m["definition"])
            t.width = asInt(m["vwidth"]); t.height = asInt(m["vheight"])
            t.size = asInt(m["size"]); t.codec = asStr(m["codec_type"])
            t.url = asStr(it["main_url"]).isEmpty ? asStr(it["backup_url"]) : asStr(it["main_url"])
            t.spadeA = asStr(e["spade_a"])
            return t
        }.filter { !$0.url.isEmpty }
        return .success(list)
    }

    /// 取流（单入口）：任一套 profile 通就返回；全不通抛错。
    static func videoModel(_ vid: String) async throws -> [VideoTrack] {
        for p in profiles {
            if case .success(let t) = await attempt(p, vid: vid), !t.isEmpty { return t }
        }
        throw ApiError.noData
    }

    // MARK: - 公网明文备用源

    /// 公网明文档位候选（从高到低）。实测站点目前只放了 360p，
    /// 但探测很便宜，哪天放出更高档位就能自动用上。
    static let publicQualities: [(String, Int, Int)] = [
        ("1080p", 1080, 1920), ("720p", 720, 1280), ("540p", 540, 960),
        ("480p", 480, 854), ("360p", 360, 640),
    ]

    /// 探测单个公网档位是否存在
    static func publicProbe(_ vid: String, _ name: String, _ w: Int, _ h: Int,
                            note: String) async -> VideoTrack? {
        let s = "https://hongguoduanju.com/video/public/\(vid)/\(name).mp4"
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = "HEAD"
        r.timeoutInterval = 12
        r.setValue(BROWSER_UA, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              let hh = resp as? HTTPURLResponse, hh.statusCode == 200 else { return nil }
        var t = VideoTrack()
        t.definition = "公开\(name)"
        t.width = w; t.height = h
        t.size = Int(max(hh.expectedContentLength, 0))
        t.codec = "avc1"; t.url = s; t.spadeA = ""
        t.note = note
        return t
    }

    /// 并发探测全部公网档位，取存在的最高一档
    static func publicBest(_ vid: String, note: String) async -> VideoTrack? {
        let found = await withTaskGroup(of: VideoTrack?.self) { group -> [VideoTrack] in
            for c in publicQualities {
                group.addTask { await publicProbe(vid, c.0, c.1, c.2, note: note) }
            }
            var acc: [VideoTrack] = []
            for await t in group { if let t { acc.append(t) } }
            return acc
        }
        return found.max {
            let a = min($0.width, $0.height), b = min($1.width, $1.height)
            return a < b
        }
    }

    // MARK: - 编解码判断

    /// 该编码能否**直接**交给 AVFoundation 解码。
    /// bytevc1 -> MP4 里是 hvc1（标准 HEVC），AVPlayer 能解；h265 / hev1 / hevc 同理；
    /// avc1 / avc3 是 H.264。
    /// bytevc2 -> MP4 里是 bvc2（字节自研私有编码），VideoToolbox 明确返回
    ///            kVTCouldNotFindVideoDecoderErr(-12906)，直接播必然黑屏 ——
    ///            这类档位不再丢弃，而是交给本机转码补齐（见 Transcoder.swift）。
    static func isPlayableCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        if c.isEmpty { return true }
        return c == "bytevc1" || c == "hvc1" || c == "hev1" || c == "h265"
            || c == "hevc" || c == "avc1" || c == "avc3"
    }

    /// 这条档位需要本机转码才能播（源站给了，但 iOS 没有这个解码器）
    static func needsTranscode(_ track: VideoTrack) -> Bool {
        guard !track.spadeA.isEmpty else { return false }
        return !isPlayableCodec(track.codec)
    }

    /// 清晰度从高到低：先比短边，再比体量
    static func sorted(_ list: [VideoTrack]) -> [VideoTrack] {
        list.sorted {
            let a = min($0.width, $0.height), b = min($1.width, $1.height)
            if a != b { return a > b }
            return $0.size > $1.size
        }
    }

    /// 能直接播的档位子集
    static func playable(_ list: [VideoTrack]) -> [VideoTrack] {
        list.filter { isPlayableCodec($0.codec) }
    }

    /// 本机转码的输入源：可解码档位里清晰度最高的一条
    static func transcodeSource(_ list: [VideoTrack]) -> VideoTrack? {
        playable(list).max {
            let a = min($0.width, $0.height), b = min($1.width, $1.height)
            if a != b { return a < b }
            return $0.size < $1.size
        }
    }

    // MARK: - 对外入口

    /// 把多次失败原因压成一句人话：相同原因合并计数
    static func reasonSummary(_ reasons: [String]) -> String {
        var order: [String] = []
        var count: [String: Int] = [:]
        for r in reasons {
            if count[r] == nil { order.append(r) }
            count[r, default: 0] += 1
        }
        return order.map { c in
            let n = count[c] ?? 1
            return n > 1 ? "\(c)×\(n)" : c
        }.joined(separator: "、")
    }

    /// 全部档位，**一条都不过滤**，按清晰度从高到低。
    /// 播不了的档位也照样返回，由播放器决定走本机转码。
    /// 接口全不通时回退公网明文，并把失败原因写进 `note`。
    static func allTracks(for vid: String) async -> [VideoTrack] {
        var reasons: [String] = []
        for p in profiles {
            switch await attempt(p, vid: vid) {
            case .success(let t):
                if !t.isEmpty { return sorted(t) }
                reasons.append("空档位")
            case .failure(let e):
                reasons.append(e.why)
            }
        }
        let why = "高清接口无档位(\(reasonSummary(reasons)))"
        if let f = await publicBest(vid, note: why) { return [f] }
        return []
    }

    /// 统一取流：优先给能直接播的档位；一条都直接播不了时，把原始档位交出去
    /// 交给 prepareForPlayback 做本机转码，而不是回退成「没有片源」。
    static func tracks(for vid: String) async -> [VideoTrack] {
        let all = await allTracks(for: vid)
        let ok = playable(all)
        return ok.isEmpty ? all : sorted(ok)
    }
}

/// 取流失败原因（单句，给用户看）
struct FetchError: Error {
    let why: String
    init(_ w: String) { why = w }
}