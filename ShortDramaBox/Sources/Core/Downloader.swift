import Foundation

/// 下载 -> 解密 -> 去 CENC -> 缓存为可播放 mp4
enum MediaStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func cachedPath(vid: String, definition: String) -> URL {
        dir.appendingPathComponent("\(vid)_\(definition).mp4")
    }

    /// 缓存上限 1.5GB，超出时按最后访问时间淘汰最旧的
    static var limitBytes: Int64 = 1_500 * 1024 * 1024

    static func pruneIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        var entries: [(URL, Date, Int64)] = []
        var total: Int64 = 0
        for f in files where f.pathExtension == "mp4" {
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = Int64(v?.fileSize ?? 0)
            entries.append((f, v?.contentModificationDate ?? .distantPast, size))
            total += size
        }
        guard total > limitBytes else { return }
        for (u, _, sz) in entries.sorted(by: { $0.1 < $1.1 }) {
            try? fm.removeItem(at: u)
            total -= sz
            if total <= limitBytes { break }
        }
    }

    /// 已有缓存则直接返回
    static func existing(vid: String, definition: String) -> URL? {
        let u = cachedPath(vid: vid, definition: definition)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    @discardableResult
    static func prepare(vid: String, track: VideoTrack,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let c = existing(vid: vid, definition: track.definition) {
            // 刷新访问时间，便于 LRU 淘汰
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: c.path)
            progress(1.0); return c
        }
        guard let url = URL(string: track.url) else { throw ApiError.badURL }
        var r = URLRequest(url: url)
        r.timeoutInterval = 60
        r.setValue(BROWSER_UA, forHTTPHeaderField: "User-Agent")
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw ApiError.http(h.statusCode) }
        let total = max(resp.expectedContentLength, Int64(track.size))
        var data = Data(); data.reserveCapacity(Int(max(total, 1)))
        var lastTick = 0
        for try await b in bytes {
            data.append(b)
            if data.count - lastTick > 262_144 {
                lastTick = data.count
                progress(total > 0 ? min(0.9, Double(data.count) / Double(total) * 0.9) : 0.4)
            }
        }
        guard !data.isEmpty else { throw ApiError.noData }
        progress(0.92)

        // 公开备用源是明文，直接落盘，跳过解密与去 CENC
        if track.spadeA.isEmpty {
            let plain = cachedPath(vid: vid, definition: track.definition)
            try data.write(to: plain)
            pruneIfNeeded()
            progress(1.0)
            return plain
        }

        // 写临时密文 -> 解密 -> 去 CENC
        let tmp = dir.appendingPathComponent("tmp_\(UUID().uuidString).mp4")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let key = spadeToKey(track.spadeA) else { throw ApiError.noData }
        let dec = tmp.appendingPathExtension("dec.mp4")
        let stats = decryptAV(tmp.path, keyHex: key, outPath: dec.path)
        defer { try? FileManager.default.removeItem(at: dec) }
        guard let v = stats["vide"], v.0 > 0 else { throw ApiError.noData }
        progress(0.97)
        let out = cachedPath(vid: vid, definition: track.definition)
        _ = stripCENC(dec.path, outPath: out.path)
        pruneIfNeeded()
        progress(1.0)
        return out
    }

    /// 档位名 -> Rendition；识别不了就按实际短边就近推断。
    static func rendition(for track: VideoTrack) -> Rendition? {
        if let r = Rendition(rawValue: track.definition) { return r }
        let edge = min(track.width, track.height)
        guard edge > 0 else { return nil }
        return Rendition.matching(shortEdge: edge) ?? Rendition.nearest(atMost: edge)
    }

    /// 取一条能直接交给 AVPlayer 的本地文件。
    ///
    /// - 轨道本身能解码 -> 下载 + 解密后返回
    /// - 轨道是 bytevc2 这类本机解不了的编码 -> 先下载同 vid 里可解码的最高清晰度档，
    ///   解密后本机转码到该档位的分辨率，返回转码结果（已缓存则直接复用）
    ///
    /// 这样源站给的档位一条都不丢，播不了的在本地补齐。
    @discardableResult
    static func prepareForPlayback(
        vid: String, track: VideoTrack, pool: [VideoTrack],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        // 公开明文备用源、以及标准编码，直接走原流程
        guard PlayerAPI.needsTranscode(track) else {
            return try await prepare(vid: vid, track: track, progress: progress)
        }
        // 需要本机转码：先找到能解码的输入源
        guard let source = PlayerAPI.transcodeSource(pool) else {
            throw TranscoderError.noVideoTrack
        }
        let edge = max(min(track.width, track.height), 1)
        guard let target = rendition(for: track) ?? Rendition.nearest(atMost: edge) else {
            // 连目标档位都认不出来：退回可解码的源，至少保证能播
            return try await prepare(vid: vid, track: source, progress: progress)
        }
        // 源本身不比目标大：转码只会放大，直接用源
        let sourceEdge = min(source.width, source.height)
        if sourceEdge > 0, sourceEdge <= target.shortEdge {
            return try await prepare(vid: vid, track: source, progress: progress)
        }
        let decrypted = try await prepare(vid: vid, track: source) { p in
            progress(p * 0.45)
        }
        return try await Transcoder.transcode(source: decrypted, rendition: target) { p in
            progress(0.45 + p * 0.55)
        }
    }
}
