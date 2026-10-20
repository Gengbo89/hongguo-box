import SwiftUI
import AVKit

/// 倍速选项
let SPEEDS: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

struct PlayerView: View {
    let series: Series
    let episodes: [Episode]
    @State private var current: Episode
    @Environment(\.dismiss) private var dismiss

    @State private var speed: Float = 1.0
    @State private var showPanel = false
    @State private var scrolledID: Int?
    /// 每集自己解析出来的清晰度，key 是集号
    @State private var qualityOf: [Int: String] = [:]
    @State private var preferredQuality: String? = nil

    init(series: Series, episodes: [Episode], start: Episode) {
        self.series = series; self.episodes = episodes; _current = State(initialValue: start)
        _scrolledID = State(initialValue: start.index)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // 竖向分页：一页一集，上下滑切换
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(episodes) { ep in
                            EpisodePage(
                                series: series,
                                episode: ep,
                                isActive: ep.index == current.index,
                                speed: speed,
                                forceQuality: preferredQuality,
                                onQuality: { q in qualityOf[ep.index] = q },
                                onEnded: {
                                    // 播完自动跳下一集（页面会跟着滑过去）
                                    if let nxt = episodes.first(where: { $0.index == ep.index + 1 }) {
                                        current = nxt
                                        scrolledID = nxt.index
                                    }
                                }
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                            .id(ep.index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrolledID)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }
        }
        .onChange(of: scrolledID) { v in
            if let v, let e = episodes.first(where: { $0.index == v }) { current = e }
        }
        .overlay(alignment: .topLeading) { topBar }
        .sheet(isPresented: $showPanel) { panel }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                    .padding(9).background(.black.opacity(0.45)).clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(series.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("第 \(current.index) 集 / \(episodes.count)")
                    if let q = qualityOf[current.index] {
                        Text("·").opacity(0.5)
                        Text(q)
                    }
                    if speed != 1.0 {
                        Text("·").opacity(0.5)
                        Text(String(format: "%gx", speed)).foregroundStyle(.pink)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button { showPanel.toggle() } label: {
                Image(systemName: "list.bullet").font(.system(size: 15, weight: .bold))
                    .padding(9).background(.black.opacity(0.45)).clipShape(Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal).padding(.top, 8)
    }

    private var panel: some View {
        NavigationStack {
            List {
                Section("倍速") {
                    ForEach(SPEEDS, id: \.self) { s in
                        Button {
                            speed = s
                        } label: {
                            HStack {
                                Text(s == 1.0 ? "1x（正常）" : String(format: "%gx", s))
                                Spacer()
                                if speed == s { Image(systemName: "checkmark").foregroundStyle(.pink) }
                            }
                        }
                    }
                }

                Section("清晰度") {
                    if qualityOf[current.index] == nil {
                        Text("正在解析…").foregroundStyle(.secondary).font(.footnote)
                    } else {
                        // 只列真实存在的档位；换清晰度对当前集生效
                        ForEach(qualityChoices, id: \.self) { q in
                            Button {
                                preferredQuality = q
                            } label: {
                                HStack {
                                    Text(q)
                                    Spacer()
                                    if qualityOf[current.index] == q {
                                        Image(systemName: "checkmark").foregroundStyle(.pink)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("选集") {
                    ForEach(episodes) { ep in
                        Button {
                            showPanel = false
                            current = ep
                            scrolledID = ep.index   // 分页跟着滚过去
                        } label: {
                            HStack {
                                Text("第 \(ep.index) 集")
                                Spacer()
                                if ep.index == current.index {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.pink)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("上下滑动可直接切换上一集/下一集")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("播放设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showPanel = false } } }
        }
    }

    /// 已知的清晰度档位（从已解析过的集里汇总）
    private var qualityChoices: [String] {
        let base = ["1080p", "720p", "540p", "480p", "360p", "公开360p"]
        let known = Set(qualityOf.values)
        let hit = base.filter { known.contains($0) }
        return hit.isEmpty ? base : hit
    }
}

// MARK: - 单集页面（自己管自己的播放器）

private struct EpisodePage: View {
    let series: Series
    let episode: Episode
    let isActive: Bool
    let speed: Float
    let forceQuality: String?
    var onQuality: (String) -> Void
    var onEnded: () -> Void

    @State private var player: AVPlayer?
    @State private var tracks: [VideoTrack] = []
    @State private var status = "准备中…"
    @State private var progress: Double = 0
    @State private var ready = false
    @State private var timeObs: Any?
    @State private var endObs: NSObjectProtocol?
    @State private var started = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let p = player, ready {
                VideoPlayer(player: p)
            } else {
                VStack(spacing: 14) {
                    if failed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30)).foregroundStyle(.orange)
                        Text(status).font(.footnote).foregroundStyle(.white.opacity(0.85))
                        Text("上下滑动换一集").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    } else {
                        ProgressView(value: progress).tint(.pink).frame(width: 220)
                        Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .onChange(of: isActive) { act in
            if act { Task { await start() } } else { player?.pause() }
        }
        .onChange(of: speed) { s in applySpeed(s) }
        .onChange(of: forceQuality) { _ in
            // 换清晰度：重新拉这一集
            if isActive, forceQuality != nil { Task { await start(force: true) } }
        }
        .onAppear { if isActive { Task { await start() } } }
        .onDisappear { cleanup() }
    }

    private func applySpeed(_ s: Float) {
        player?.defaultRate = s
        if player?.timeControlStatus == .playing { player?.rate = s }
    }

    private func cleanup() {
        if let o = timeObs { player?.removeTimeObserver(o); timeObs = nil }
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        player?.pause(); player = nil
    }

    private static func pick(_ list: [VideoTrack], force: String?) -> VideoTrack? {
        let ok = list.filter { PlayerAPI.isPlayableCodec($0.codec) }
        let pool = ok.isEmpty ? list : ok
        if let f = force, let t = pool.first(where: { $0.definition == f }) { return t }
        if let p = pool.last(where: { $0.definition.contains("1080") }) { return p }
        return pool.last
    }

    private func start(force: Bool = false) async {
        if started && !force { applySpeed(speed); player?.play(); return }
        started = true
        failed = false
        ready = false; progress = 0; status = "获取播放地址…"
        if let o = timeObs { player?.removeTimeObserver(o); timeObs = nil }
        player?.pause(); player = nil

        do {
            if tracks.isEmpty {
                tracks = await PlayerAPI.tracks(for: episode.vid)
                if tracks.isEmpty {
                    status = "该集暂无可用片源"; failed = true; return
                }
            }
            guard let best = Self.pick(tracks, force: forceQuality) else {
                status = "无可用清晰度"; failed = true; return
            }
            onQuality(best.definition)

            let url = try await MediaStore.prepare(vid: episode.vid, track: best) { p in
                Task { @MainActor in
                    progress = p; status = "下载并解密中 \(Int(p * 100))%"
                }
            }
            let p = AVPlayer(url: url)
            p.defaultRate = speed
            player = p

            // 续播
            let at = WatchStore.shared.progress(seriesId: series.id)
                .flatMap { $0.episode == episode.index ? $0.seconds : nil } ?? 0
            if at > 3 {
                await p.seek(to: CMTime(seconds: at, preferredTimescale: 600))
            }
            p.play()
            if speed != 1.0 { p.rate = speed }
            ready = true

            timeObs = p.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { t in
                let sec = CMTimeGetSeconds(t)
                guard sec.isFinite, sec > 0 else { return }
                WatchStore.shared.record(seriesId: series.id, title: series.title,
                                         cover: series.cover, episode: episode.index, seconds: sec)
            }

            // 播完自动下一集
            if let o = endObs { NotificationCenter.default.removeObserver(o) }
            endObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                Task { @MainActor in onEnded() }
            }
        } catch {
            status = "加载失败: \(error)"; failed = true
        }
    }
}