import Foundation

/// 单次下载：用 URLSessionDownloadTask 边下边写盘，同时汇报进度。
///
/// 之前用 `URLSession.bytes(for:)` 逐字节 async 迭代（每次 await 只出 1 个字节），
/// 一个几十 MB 的 1080p 剧集要几千万次 async 恢复；而且整段视频先攒在内存里再落盘，
/// 推荐页再并发预取几路，内存直接几百 MB —— 卡就卡在这里。
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let dest: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var cont: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(expected: Int64, dest: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.dest = dest
        self.onProgress = onProgress
    }

    func run(_ request: URLRequest) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.lock(); cont = c; lock.unlock()
                let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                lock.lock(); session = s; lock.unlock()
                let t = s.downloadTask(with: request)
                lock.lock(); task = t; lock.unlock()
                t.resume()
            }
        } onCancel: {
            // 只取消 Swift 任务停不掉 URLSession 的下载：切走 Tab 之后后台还在继续下
            // 1080p，进度回调一次次把条目改回 .downloading，这一页回来就永远停在
            // 「解密中 100%」。这里把它真停掉，顺带把带宽让出来。
            lock.lock(); let t = task; lock.unlock()
            t?.cancel()
        }
    }

    /// 只允许收尾一次；顺手把 session 作废，断开它对 delegate 的强引用
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let c = cont; cont = nil
        let s = session; session = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
        c?.resume(with: result)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let t = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard t > 0 else { onProgress(0.4); return }
        onProgress(min(0.9, Double(totalBytesWritten) / Double(t) * 0.9))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let h = downloadTask.response as? HTTPURLResponse, h.statusCode != 200 {
            finish(.failure(ApiError.http(h.statusCode))); return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(.failure(error))
    }
}

/// 全局解密闸门：同时最多 1 路。
///
/// 解密 + 去 CENC 是纯 CPU + 一次性把整个文件读进内存的活。
/// 播放页在前台播 1080p、后台预取又在解密下一集的话，两路同时开工
/// 内存和 CPU 都会出现尖峰；串行化之后总耗时几乎不变（单集解密 0.4 秒），
/// 但尖峰不见了。
actor DecryptGate {
    static let shared = DecryptGate(limit: 1)
    private let limit: Int
    private var active = 0
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { queue.append($0) }
    }

    func release() {
        if queue.isEmpty { active = max(0, active - 1) }
        else { queue.removeFirst().resume() }
    }
}

/// 全局下载闸门：同时最多 2 路。
actor DownloadGate {
    static let shared = DownloadGate(limit: 2)
    private let limit: Int
    private var active = 0
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit { active += 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.append(c)
        }
        active += 1
    }

    func release() {
        active -= 1
        if !queue.isEmpty { queue.removeFirst().resume() }
    }
}

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
    /// 下载/解密的半成品一律放这个子目录。
    /// 原来半成品直接叫 dl_xxx.mp4 躺在缓存目录里：一是被 pruneIfNeeded
    /// 当成成品按 LRU 删掉（下载中途文件没了），二是和成品混在一起不好排查。
    static var tmpDir: URL {
        let d = dir.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
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
        // 10 分钟内碰过的一律不动 —— 里面可能有正在播的那一集。
        // 把正在播的文件删掉，表现就是「看着看着突然解码不出来」。
        let cutoff = Date().addingTimeInterval(-600)
        for (u, date, sz) in entries.sorted(by: { $0.1 < $1.1 }) {
            guard date < cutoff else { continue }
            try? fm.removeItem(at: u)
            total -= sz
            if total <= limitBytes { break }
        }
    }

    /// 已有缓存且完整才返回。
    ///
    /// 只判断「文件在不在」是不够的：写到一半被杀、并发读到半成品、
    /// 磁盘写满，都会留下一个存在但残缺的 mp4。交给 AVPlayer 就是
    /// 「某一集解码不出来」，而且它一直被当成缓存命中 —— 重进多少次都还是坏的。
    /// 发现不完整就直接删掉重下。
    static func existing(vid: String, definition: String) -> URL? {
        let u = cachedPath(vid: vid, definition: definition)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        guard looksPlayable(u) else {
            try? FileManager.default.removeItem(at: u)
            return nil
        }
        return u
    }

    /// 丢掉这一档的成品缓存（播放页「重新加载」用）。
    /// 光重试是没用的：existing() 会把同一个坏文件再交回来。
    static func invalidate(vid: String, definition: String) {
        try? FileManager.default.removeItem(at: cachedPath(vid: vid, definition: definition))
    }

    /// 顺着顶层盒子链走一遍，判断这个 mp4 是不是完整的。
    ///
    /// 只读盒头（每个盒子一次 seek），几十 MB 也就几十次读，开销可以忽略。
    /// 判据：盒子链能走通、看过 moov、见过媒体数据，且没有一个盒子
    /// 声称的长度超出文件末尾 —— 截断一定会在这条上暴露。
    /// 末尾的多余字节不算错（有些源站会补零），所以不要求正好走到 EOF。
    static func looksPlayable(_ u: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? fh.close() }
        guard let total = try? fh.seekToEnd(), total >= 16 else { return false }
        var off: UInt64 = 0
        var sawMoov = false, sawMedia = false
        while off + 8 <= total {
            try? fh.seek(toOffset: off)
            guard let hdr = try? fh.read(upToCount: 16), hdr.count >= 8 else { break }
            let b = [UInt8](hdr)
            func be32(_ i: Int) -> UInt64 {
                (UInt64(b[i]) << 24) | (UInt64(b[i+1]) << 16) | (UInt64(b[i+2]) << 8) | UInt64(b[i+3])
            }
            var size = be32(0)
            let type = String(bytes: b[4..<8], encoding: .ascii) ?? "????"
            if size == 1 {
                guard b.count >= 16 else { return false }
                var v: UInt64 = 0
                for i in 8..<16 { v = (v << 8) | UInt64(b[i]) }
                size = v
            } else if size == 0 {
                size = total - off
            }
            // 盒头都读不出长度：当成尾部填充，前面拿到的结论仍然有效
            guard size >= 8 else { break }
            // 声称的长度超出文件末尾 = 截断，这个必须判死
            guard off + size <= total else { return false }
            if type == "moov" { sawMoov = true }
            if type == "mdat" || type == "moof" { sawMedia = true }
            off += size
        }
        return sawMoov && sawMedia
    }

    /// 半成品原子换名到最终路径：让成品路径上永远只有完整文件。
    /// 直接往成品路径写的话，并发读到的就是半截文件。
    static func install(_ tmp: URL, at dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
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

        await DownloadGate.shared.acquire()
        let staged: URL
        do {
            staged = try await download(url, expect: Int64(track.size), progress: progress)
        } catch {
            await DownloadGate.shared.release()
            throw error
        }
        await DownloadGate.shared.release()
        defer { try? FileManager.default.removeItem(at: staged) }
        progress(0.92)

        // 公开备用源是明文，直接落盘，跳过解密与去 CENC
        if track.spadeA.isEmpty {
            let plain = cachedPath(vid: vid, definition: track.definition)
            try install(staged, at: plain)
            pruneIfNeeded()
            progress(1.0)
            return plain
        }

        // 加密轨：先确认下载下来的确实是完整 MP4，再交给解密器。
        //
        // 下载被中途掐断（连接断了但 URLSession 没报错）时，文件里的 stco/stsz
        // 指向的样本偏移会落在这个短文件的末尾之外。解密器是按文件里的偏移
        // 去写字节的 —— 校验这一道就是不让残缺文件进解密器（以前就是这样闪退的）。
        guard looksPlayable(staged) else {
            try? FileManager.default.removeItem(at: staged)
            throw ApiError.noData
        }

        // 临时密文 -> 解密 -> 去 CENC（全局串行，避免播放与预取同时解密造成尖峰）
        guard let key = spadeToKey(track.spadeA) else { throw ApiError.noData }
        let dec = staged.appendingPathExtension("dec.mp4")
        defer { try? FileManager.default.removeItem(at: dec) }

        await DecryptGate.shared.acquire()
        let out = cachedPath(vid: vid, definition: track.definition)
        do {
            let stats = decryptAV(staged.path, keyHex: key, outPath: dec.path)
            guard let v = stats["vide"], v.0 > 0 else { throw ApiError.noData }
            progress(0.97)
            // 先写到 .part，校验通过再原子换名。
            // 原来是 `_ = stripCENC(dec.path, outPath: out.path)`：直接写成品路径，
            // 返回值（-1 = 失败）被丢掉 —— strip 失败也照样返回「成功」，
            // 于是把一个残缺文件交给 AVPlayer，就是那一集「解码不出来」。
            let part = out.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: part)
            let delta = stripCENC(dec.path, outPath: part.path)
            guard delta != -1, looksPlayable(part) else {
                try? FileManager.default.removeItem(at: part)
                throw ApiError.noData
            }
            try install(part, at: out)
        } catch {
            await DecryptGate.shared.release()
            throw error
        }
        await DecryptGate.shared.release()
        pruneIfNeeded()
        progress(1.0)
        return out
    }

    /// 下载到本地临时文件（边下边写盘，不在内存里攒整段视频）
    private static func download(_ url: URL, expect: Int64,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        var r = URLRequest(url: url)
        r.timeoutInterval = 120
        r.setValue(BROWSER_UA, forHTTPHeaderField: "User-Agent")
        let staged = tmpDir.appendingPathComponent("dl_\(UUID().uuidString).mp4")
        let d = FileDownloader(expected: expect, dest: staged, onProgress: progress)
        let out = try await d.run(r)
        let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: out)
            throw ApiError.noData
        }
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
        HGLog.i("取流", "\(track.definition) vid=\(vid) 需转码=" + (PlayerAPI.needsTranscode(track) ? "是" : "否"))
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
