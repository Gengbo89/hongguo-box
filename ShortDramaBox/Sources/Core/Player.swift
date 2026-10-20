import Foundation

/// 游客身份取流：无需签名 / 登录 / Cookie（逆向自桌面版后端，实测可用）
enum PlayerAPI {
    static let host = "https://api5-normal-sinfonlineb.fqnovel.com"
    static let path = "/novel/player/video_model/v1/"

    static var query: String {
        let p: [(String, String)] = [
            ("aid", "8662"), ("app_name", "novelread"), ("version_code", "73532"),
            ("version_name", "7.3.5.32"), ("manifest_version_code", "73532"),
            ("update_version_code", "73532"), ("channel", "update_64"),
            ("device_platform", "android"), ("os", "android"), ("ssmix", "a"),
            ("device_type", "25053RT47C"), ("device_brand", "Redmi"), ("language", "zh"),
            ("os_api", "36"), ("os_version", "16"), ("resolution", "1280*2772"),
            ("dpi", "520"), ("ac", "wifi"),
        ]
        return p.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }
    static let ua = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; "
        + "Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 "
        + "QuicVersion:c67e9834 2025-09-08)"

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

    static func videoModel(_ vid: String) async throws -> [VideoTrack] {
        let g = guestDevice
        let q = query + "&device_id=\(g.id)&iid=\(g.iid)"
        guard let u = URL(string: host + path + "?" + q) else { throw ApiError.badURL }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue(ua, forHTTPHeaderField: "user-agent")
        r.setValue("application/json", forHTTPHeaderField: "accept")
        r.setValue("0", forHTTPHeaderField: "x-xs-from-web")
        r.setValue("2", forHTTPHeaderField: "sdk-version")
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "video_id": vid, "content_type": 1,
            "biz_param": ["need_all_video_definition": true, "video_platform": 3],
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = asInt(root["code"])
        if code != 0 { throw ApiError.server(code, asStr(root["message"])) }
        guard let inner = asStr(asDict(root["data"])["video_model"]).data(using: .utf8),
              let vm = (try? JSONSerialization.jsonObject(with: inner)) as? [String: Any]
        else { throw ApiError.noData }
        return asArr(vm["video_list"]).map { raw in
            let it = asDict(raw), m = asDict(it["video_meta"]), e = asDict(it["encrypt_info"])
            var t = VideoTrack()
            t.definition = asStr(m["definition"])
            t.width = asInt(m["vwidth"]); t.height = asInt(m["vheight"])
            t.size = asInt(m["size"]); t.codec = asStr(m["codec_type"])
            t.url = asStr(it["main_url"]).isEmpty ? asStr(it["backup_url"]) : asStr(it["main_url"])
            t.spadeA = asStr(e["spade_a"])
            return t
        }.filter { !$0.url.isEmpty }
    }

    /// 公开 360p 明文备用源（H.264，无需解密）；存在才返回
    static func publicFallback(_ vid: String) async -> VideoTrack? {
        let s = "https://hongguoduanju.com/video/public/\(vid)/360p.mp4"
        guard let u = URL(string: s) else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = "HEAD"
        r.timeoutInterval = 12
        r.setValue(BROWSER_UA, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return nil }
        var t = VideoTrack()
        t.definition = "公开360p"
        t.width = 360; t.height = 640
        t.size = Int(max(h.expectedContentLength, 0))
        t.codec = "avc1"; t.url = s; t.spadeA = ""
        return t
    }

    /// 该编码能否**直接**交给 AVFoundation 解码。
    /// bytevc1 -> MP4 里是 hvc1（标准 HEVC），AVPlayer 能解；h265 / hev1 / hevc 同理；
    /// avc1 / avc3 是 H.264。
    /// bytevc2 -> MP4 里是 bvc2（字节自研私有编码），VideoToolbox 明确返回
    ///            kVTCouldNotFindVideoDecoderErr(-12906)，直接播必然黑屏 ——
    ///            这类档位不再丢弃，而是交给本机转码补齐（见 Transcoder.swift）。
    static func isPlayableCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        if c.isEmpty { return true }              // 编码未知时不武断排除
        return c == "bytevc1" || c == "hvc1" || c == "hev1" || c == "h265"
            || c == "hevc" || c == "avc1" || c == "avc3"
    }

    /// 这条档位需要本机转码才能播（源站给了，但 iOS 没有这个解码器）
    static func needsTranscode(_ track: VideoTrack) -> Bool {
        guard !track.spadeA.isEmpty else { return false }   // 公开明文源是 H.264
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

    /// 本机转码的输入源：可解码档位里清晰度最高的一条（通常 1080p 的 bytevc1）
    static func transcodeSource(_ list: [VideoTrack]) -> VideoTrack? {
        playable(list).max {
            let a = min($0.width, $0.height), b = min($1.width, $1.height)
            if a != b { return a < b }
            return $0.size < $1.size
        }
    }

    /// 全部档位，**一条都不过滤**，按清晰度从高到低。
    /// 播不了的档位也照样返回，由播放器决定走本机转码。
    static func allTracks(for vid: String) async -> [VideoTrack] {
        for attempt in 0..<3 {
            if let t = try? await videoModel(vid), !t.isEmpty { return sorted(t) }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
        if let f = await publicFallback(vid) { return [f] }
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
