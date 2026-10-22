import AVFoundation
import Foundation

/// 本机转码：把已解密的可播放版本降分辨率重编码成低清晰度档位，并缓存复用。
///
/// 源站每个 vid 都给 5 档（360p/480p/540p/720p/1080p），但低分辨率那几档常常是
/// bytevc2 —— 字节自研私有编码，iOS 没有对应解码器（VideoToolbox 对 bvc2 返回
/// kVTCouldNotFindVideoDecoderErr / -12906）。这些档位不再被过滤掉，而是用本机把
/// 能解的档位（通常是 1080p 的 bytevc1 / hvc1）转成对应分辨率，得到真正能播的版本。
///
/// 输出与源文件同目录同名：<名字>.mp4 -> <名字>.720p.mp4，已存在且非空则直接复用。
enum Rendition: String, CaseIterable, Identifiable, Sendable {
    case p1080 = "1080p", p720 = "720p", p540 = "540p", p480 = "480p", p360 = "360p"

    var id: String { rawValue }
    var label: String { rawValue }

    /// 目标短边像素（竖屏短剧的短边即宽度）
    var shortEdge: Int {
        switch self {
        case .p1080: return 1080
        case .p720: return 720
        case .p540: return 540
        case .p480: return 480
        case .p360: return 360
        }
    }

    /// 目标视频码率（bps）；按源站同档位的量级取值，保证转码后比源文件小
    var videoBitrate: Int {
        switch self {
        case .p1080: return 560_000
        case .p720: return 300_000
        case .p540: return 210_000
        case .p480: return 170_000
        case .p360: return 120_000
        }
    }

    static func matching(shortEdge edge: Int) -> Rendition? {
        allCases.first { $0.shortEdge == edge }
    }

    /// 不超过给定短边、且最接近的档位
    static func nearest(atMost edge: Int) -> Rendition? {
        allCases.filter { $0.shortEdge <= edge }.max { $0.shortEdge < $1.shortEdge }
    }
}

enum TranscoderError: LocalizedError {
    case noVideoTrack, cannotAddReaderOutput, cannotAddWriterInput, noMediaProduced
    case readerFailed(String), writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "源文件里没有视频轨，无法转码"
        case .cannotAddReaderOutput: return "转码器无法读取源文件"
        case .cannotAddWriterInput: return "转码器无法写入目标文件"
        case .readerFailed(let s): return "读取源文件失败：\(s)"
        case .writerFailed(let s): return "写入转码文件失败：\(s)"
        case .noMediaProduced: return "转码没有产出任何画面"
        }
    }
}

enum Transcoder {
    static func outputURL(for source: URL, rendition: Rendition) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent()
            .appendingPathComponent("\(stem).\(rendition.rawValue).mp4")
    }

    /// 已转好、非空、而且盒子链完整才返回缓存路径。
    /// 命中时刷新访问时间 —— 转码结果重建代价高，让它排在 LRU 淘汰的后面。
    ///
    /// 只判断「非空」不够：AVAssetWriter 把 moov 写在文件末尾，
    /// 转到一半被杀就留下一个没有 moov 的残缺 mp4。它会被永久当成命中，
    /// 于是这一集每次都「解码不出来」，重进多少次都一样。
    static func cached(for source: URL, rendition: Rendition) -> URL? {
        let url = outputURL(for: source, rendition: rendition)
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = a[.size] as? NSNumber, n.intValue > 0 else { return nil }
        guard MediaStore.looksPlayable(url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: url.path)
        return url
    }

    /// 丢掉某个源文件对应的转码结果（播放页「重新加载」用）
    static func invalidate(source: URL, rendition: Rendition) {
        try? FileManager.default.removeItem(at: outputURL(for: source, rendition: rendition))
    }

    /// 把 source 降分辨率重编码成 rendition，返回缓存后的本地文件名。
    /// 视频走 HEVC(hvc1) + AVMutableVideoComposition 缩放；音频 AAC 原样直通不重编码。
    static func transcode(
        source: URL,
        rendition: Rendition,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let hit = cached(for: source, rendition: rendition) { return hit }

        let asset = AVURLAsset(url: source,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranscoderError.noVideoTrack
        }
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 25.0

        // 显示尺寸 = 自然尺寸套上旋转矩阵，竖屏/横屏两种存储方式都兼容
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let displayW = abs(oriented.width), displayH = abs(oriented.height)
        HGLog.i("转码", "开始本机转码 \(Int(displayW))x\(Int(displayH))")
        guard displayW > 0, displayH > 0 else { throw TranscoderError.noVideoTrack }

        // 按短边等比缩放；宽高取偶数，H.264/HEVC 都要求偶数分辨率
        let scale = CGFloat(rendition.shortEdge) / min(displayW, displayH)
        func even(_ v: CGFloat) -> Int {
            let r = Int(v.rounded())
            return r % 2 == 0 ? r : r + 1
        }
        let outW = even(displayW * scale), outH = even(displayH * scale)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: outW, height: outH)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps.rounded())))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let combined = transform.concatenating(
            CGAffineTransform(scaleX: CGFloat(outW) / displayW, y: CGFloat(outH) / displayH))
        // 旋转/缩放后内容原点可能变负，平移回 (0,0) 避免被裁掉
        let placed = CGRect(origin: .zero, size: natural).applying(combined)
        layer.setTransform(
            combined.concatenating(CGAffineTransform(translationX: -placed.minX, y: -placed.minY)),
            at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let destination = outputURL(for: source, rendition: rendition)
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: destination)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw TranscoderError.cannotAddReaderOutput }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: rendition.videoBitrate,
                    AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
                    AVVideoAllowFrameReorderingKey: true
                ] as [String: Any]
            ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw TranscoderError.cannotAddWriterInput }
        writer.add(videoInput)

        // 音频直通：压缩样本原样搬运，AAC -> mp4 的 mp4a
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let at = try await asset.loadTracks(withMediaType: .audio).first,
           let fmt = try await at.load(.formatDescriptions).first {
            let out = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            if reader.canAdd(out) { reader.add(out); audioOutput = out }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                          sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        guard writer.startWriting() else {
            throw TranscoderError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting 返回 false")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw TranscoderError.readerFailed(
                reader.error?.localizedDescription ?? "startReading 返回 false")
        }

        let expected = max(1, Int((CMTimeGetSeconds(duration) * fps).rounded()))
        var videoDone = false
        var audioDone = (audioInput == nil)
        var written = 0, lastReported = -1

        while !(videoDone && audioDone) {
            try Task.checkCancellation()
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let buf = videoOutput.copyNextSampleBuffer() {
                    if videoInput.append(buf) {
                        written += 1
                        let pct = min(99, written * 100 / expected)
                        if pct != lastReported { lastReported = pct; progress?(Double(pct) / 100) }
                    } else { videoDone = true }
                } else { videoInput.markAsFinished(); videoDone = true }
            }
            if !audioDone, let input = audioInput, let output = audioOutput,
               input.isReadyForMoreMediaData {
                if let buf = output.copyNextSampleBuffer() {
                    if !input.append(buf) { audioDone = true }
                } else { input.markAsFinished(); audioDone = true }
            }
            if !(videoDone && audioDone) { try await Task.sleep(nanoseconds: 2_000_000) }
        }

        await writer.finishWriting()

        guard writer.status == .completed, written > 0 else {
            try? FileManager.default.removeItem(at: partial)
            if writer.status == .cancelled { throw CancellationError() }
            throw TranscoderError.writerFailed(
                writer.error?.localizedDescription
                    ?? "状态 \(writer.status.rawValue)，写入 \(written) 帧")
        }
        guard let sz = try? FileManager.default
                .attributesOfItem(atPath: partial.path)[.size] as? NSNumber,
              sz.intValue > 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw TranscoderError.noMediaProduced
        }
        // 换名前再验一次盒子链：残缺文件绝不放到成品路径上
        guard MediaStore.looksPlayable(partial) else {
            try? FileManager.default.removeItem(at: partial)
            throw TranscoderError.noMediaProduced
        }
        try MediaStore.install(partial, at: destination)
        progress?(1.0)
        return destination
    }
}
