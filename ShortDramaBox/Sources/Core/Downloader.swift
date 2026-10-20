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

    init(expected: Int64, dest: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.dest = dest
        self.onProgress = onProgress
    }

    func run(_ request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            lock.lock(); cont = c; lock.unlock()
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            lock.lock(); session = s; lock.unlock()
            s.downloadTask(with: request).resume()
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
            try? FileManager.default.removeItem(at: plain)
            try FileManager.default.moveItem(at: staged, to: plain)
            pruneIfNeeded()
            progress(1.0)
            return plain
        }

        // 临时密文 -> 解密 -> 去 CENC
        guard let key = spadeToKey(track.spadeA) else { throw ApiError.noData }
        let dec = staged.appendingPathExtension("dec.mp4")
        defer { try? FileManager.default.removeItem(at: dec) }
        let stats = decryptAV(staged.path, keyHex: key, outPath: dec.path)
        guard let v = stats["vide"], v.0 > 0 else { throw ApiError.noData }
        progress(0.97)
        let out = cachedPath(vid: vid, definition: track.definition)
        _ = stripCENC(dec.path, outPath: out.path)
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
        let staged = dir.appendingPathComponent("dl_\(UUID().uuidString).mp4")
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
