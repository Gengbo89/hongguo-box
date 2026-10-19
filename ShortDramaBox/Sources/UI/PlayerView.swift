import SwiftUI
import AVKit

struct PlayerView: View {
    let series: Series
    let episodes: [Episode]
    @State private var current: Episode
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var tracks: [VideoTrack] = []
    @State private var quality: String = ""
    @State private var status: String = "准备中…"
    @State private var progress: Double = 0
    @State private var ready = false
    @State private var timeObs: Any?
    @State private var endObs: NSObjectProtocol?
    @State private var showPanel = false

    init(series: Series, episodes: [Episode], start: Episode) {
        self.series = series; self.episodes = episodes; _current = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player, ready {
                VideoPlayer(player: p).ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    ProgressView(value: progress).tint(.pink).frame(width: 220)
                    Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8))
                    if !tracks.isEmpty {
                        Text("清晰度: \(quality)").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                        .padding(9).background(.black.opacity(0.45)).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("第 \(current.index) 集 / \(episodes.count)").font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Button { showPanel.toggle() } label: {
                    Image(systemName: "list.bullet").font(.system(size: 15, weight: .bold))
                        .padding(9).background(.black.opacity(0.45)).clipShape(Circle())
                }
            }
            .foregroundStyle(.white).padding(.horizontal).padding(.top, 8)
        }
        .sheet(isPresented: $showPanel) { panel }
        .task { await start(current) }
        .onDisappear { cleanup() }
    }
}

extension PlayerView {
    private var panel: some View {
        NavigationStack {
            List {
                Section("清晰度") {
                    ForEach(tracks, id: \.definition) { t in
                        Button {
                            showPanel = false
                            Task { await start(current, forceQuality: t.definition) }
                        } label: {
                            HStack {
                                Text("\(t.definition)  \(t.width)x\(t.height)")
                                Spacer()
                                if t.definition == quality { Image(systemName: "checkmark").foregroundStyle(.pink) }
                            }
                        }
                    }
                }
                Section("选集") {
                    ForEach(episodes) { ep in
                        Button {
                            showPanel = false
                            current = ep
                            Task { await start(ep) }
                        } label: {
                            HStack {
                                Text("第 \(ep.index) 集")
                                Spacer()
                                if ep.index == current.index { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.pink) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("播放设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showPanel = false } } }
        }
    }

    private func cleanup() {
        if let o = timeObs { player?.removeTimeObserver(o); timeObs = nil }
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        player?.pause(); player = nil
    }

    private func pick(_ list: [VideoTrack], force: String?) -> VideoTrack? {
        if let f = force, let t = list.first(where: { $0.definition == f }) { return t }
        return list.last   // 默认最高（1080p）
    }

    private func start(_ ep: Episode, forceQuality: String? = nil) async {
        ready = false; progress = 0; status = "获取播放地址…"
        timeObs.map { player?.removeTimeObserver($0) }
        player?.pause(); player = nil
        do {
            if tracks.isEmpty {
                tracks = await PlayerAPI.tracks(for: ep.vid)
                if tracks.isEmpty { status = "该集暂无可用片源，请换一集"; return }
            }
            guard let best = pick(tracks, force: forceQuality) else { status = "无可用清晰度"; return }
            quality = best.definition
            let url = try await MediaStore.prepare(vid: ep.vid, track: best) { p in
                Task { @MainActor in progress = p; status = "下载并解密中 \(Int(p * 100))%" }
            }
            let p = AVPlayer(url: url)
            player = p
            let startAt = WatchStore.shared.progress(seriesId: series.id).flatMap { $0.episode == ep.index ? $0.seconds : nil } ?? 0
            if startAt > 3 { await p.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
            p.play()
            ready = true
            timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { t in
                let sec = CMTimeGetSeconds(t)
                guard sec.isFinite, sec > 0 else { return }
                WatchStore.shared.record(seriesId: series.id, title: series.title,
                                         cover: series.cover, episode: ep.index, seconds: sec)
            }
            if let o = endObs { NotificationCenter.default.removeObserver(o) }
            endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: p.currentItem, queue: .main) { _ in
                let next = ep.index
                if next < episodes.count {
                    let e = episodes[next]
                    Task { @MainActor in current = e; await start(e) }
                }
            }
        } catch { status = "加载失败: \(error)" }
    }
}
