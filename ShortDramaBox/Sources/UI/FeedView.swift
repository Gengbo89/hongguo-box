import SwiftUI
import AVKit
import Combine

// MARK: - 单条推荐

struct FeedItem: Identifiable {
    enum Status: Equatable {
        case pending              // 还没开始解析
        case resolving            // 正在解析片源
        case downloading(Double)  // 正在下载解密
        case ready(URL)
        case failed(String)
    }
    let series: Series
    var episode: Episode?
    var status: Status = .pending
    var id: String { series.id }
}

// MARK: - 推荐流数据

@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var loading = true
    @Published private(set) var error: String?

    /// 正在准备中的剧集 id，避免重复起任务
    private var inFlight: Set<String> = []
    /// 已经准备好的视频数上限，超过就停手，省流量省电
    private let maxPrepared = 12
    private let prefetchAhead = 2

    /// 拉一批剧，顺序打散，避免每次都是同样几部
    func load() async {
        loading = true; error = nil
        var pool: [Series] = []
        if let secs = try? await Catalog.home() {
            pool += secs.flatMap { $0.items }
        }
        // 首页不够就从分类里补，保证有得刷
        if pool.count < 20 {
            for c in Catalog.categories {
                if let more = try? await Catalog.category(c.slug) { pool += more }
                if pool.count >= 60 { break }
            }
        }
        // 按 id 去重
        var seen = Set<String>()
        let uniq = pool.filter { seen.insert($0.id).inserted }
        guard !uniq.isEmpty else {
            error = "没有拿到推荐内容，检查下网络"
            loading = false
            return
        }
        items = uniq.shuffled().map { FeedItem(series: $0) }
        loading = false
    }

    /// 换一批（打散重来）
    func reshuffle() {
        items = items.shuffled()
        for i in items.indices { items[i].status = .pending; items[i].episode = nil }
        inFlight.removeAll()
    }

    /// 准备第 index 条，并顺带预取后面几条
    func prepare(_ index: Int) {
        guard items.indices.contains(index) else { return }
        for k in index...(index + prefetchAhead) where items.indices.contains(k) {
            prepareOne(k)
        }
        prunePrepared(keeping: index)
    }

    private func prepareOne(_ i: Int) {
        let item = items[i]
        if case .ready = item.status { return }
        if case .downloading = item.status { return }
        if case .resolving = item.status { return }
        if inFlight.contains(item.series.id) { return }
        inFlight.insert(item.series.id)
        items[i].status = .resolving

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.inFlight.remove(item.series.id) } }
            do {
                let (_, eps) = try await Catalog.detail(item.series.id)
                guard !eps.isEmpty else {
                    await MainActor.run { self.setStatus(i, .failed("暂无片源")) }
                    return
                }
                // 随机挑一集，和官方「随机推荐」的感觉一致
                let ep = eps.randomElement() ?? eps[0]
                let tracks = await PlayerAPI.tracks(for: ep.vid)
                guard let best = Self.best(tracks) else {
                    await MainActor.run { self.setStatus(i, .failed("无可用清晰度")) }
                    return
                }
                await MainActor.run {
                    if self.items.indices.contains(i) { self.items[i].episode = ep }
                }
                let url = try await MediaStore.prepare(vid: ep.vid, track: best) { p in
                    Task { @MainActor in self.setStatus(i, .downloading(p)) }
                }
                await MainActor.run { self.setStatus(i, .ready(url)) }
            } catch {
                await MainActor.run { self.setStatus(i, .failed("加载失败")) }
            }
        }
    }

    /// 优先 1080p（标准 HEVC），否则取可用的最高档
    static func best(_ tracks: [VideoTrack]) -> VideoTrack? {
        let ok = tracks.filter { PlayerAPI.isPlayableCodec($0.codec) }
        let list = ok.isEmpty ? tracks : ok
        if let p1080 = list.last(where: { $0.definition.contains("1080") }) { return p1080 }
        return list.last
    }

    private func setStatus(_ i: Int, _ s: FeedItem.Status) {
        guard items.indices.contains(i) else { return }
        items[i].status = s
    }

    /// 把离当前位置太远的已下载缓存清掉，避免占满磁盘
    private func prunePrepared(keeping index: Int) {
        let readyCount = items.filter { if case .ready = $0.status { return true }; return false }.count
        guard readyCount > maxPrepared else { return }
        for (i, it) in items.enumerated() where abs(i - index) > 4 {
            if case .ready = it.status { items[i].status = .pending }
        }
    }
}

// MARK: - 单页

private struct FeedCard: View {
    let item: FeedItem
    let isActive: Bool
    var onOpen: () -> Void

    @State private var player: AVPlayer?
    @State private var muted = false
    @State private var liked = false
    @State private var endObs: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black
            AsyncImage(url: URL(string: item.series.cover)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else { Color.black }
            }
            .blur(radius: player == nil ? 0 : 24)
            .overlay(Color.black.opacity(player == nil ? 0.15 : 0.5))
            .clipped()

            if let p = player {
                VideoPlayer(player: p)
                    .ignoresSafeArea()
                    .onTapGesture { togglePlay(p) }
            } else {
                loadingOverlay
            }

            // 右侧操作栏
            VStack(spacing: 22) {
                Button { liked.toggle() } label: {
                    VStack(spacing: 4) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 26))
                            .foregroundStyle(liked ? .pink : .white)
                        Text("喜欢").font(.system(size: 11)).foregroundStyle(.white)
                    }
                }
                Button { muted.toggle(); player?.isMuted = muted } label: {
                    VStack(spacing: 4) {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 22)).foregroundStyle(.white)
                        Text(muted ? "已静音" : "有声").font(.system(size: 11)).foregroundStyle(.white)
                    }
                }
                Button(action: onOpen) {
                    VStack(spacing: 4) {
                        Image(systemName: "list.bullet").font(.system(size: 22)).foregroundStyle(.white)
                        Text("选集").font(.system(size: 11)).foregroundStyle(.white)
                    }
                }
            }
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 底部信息
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                Text(item.series.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 8) {
                    if let ep = item.episode {
                        Text("第 \(ep.index) 集").font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.pink.opacity(0.85)).clipShape(Capsule())
                    }
                    Text("共 \(item.series.episodeCount) 集").font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if !item.series.intro.isEmpty {
                    Text(item.series.intro)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
                Text("上滑看下一部 · 点「选集」看完整剧集")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 16).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 240).frame(maxHeight: .infinity, alignment: .bottom)
            )
        }
        .onChange(of: isActive) { active in
            if active { start() } else { player?.pause() }
        }
        .onChange(of: item.status) { _ in syncPlayer() }
        .onAppear { if isActive { start() } }
        .onDisappear {
            player?.pause(); player = nil
            if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            switch item.status {
            case .downloading(let p):
                ProgressView(value: p).tint(.pink).frame(width: 180)
                Text("解密中 \(Int(p * 100))%").font(.footnote).foregroundStyle(.white.opacity(0.8))
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(m).font(.footnote).foregroundStyle(.white.opacity(0.8))
                Text("上滑看下一部").font(.caption2).foregroundStyle(.white.opacity(0.5))
            default:
                ProgressView().tint(.pink)
                Text("正在准备片源…").font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(20)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func start() {
        syncPlayer()
        player?.play()
    }

    private func syncPlayer() {
        guard case .ready(let url) = item.status else { return }
        if player?.currentItem?.asset is AVURLAsset,
           (player?.currentItem?.asset as? AVURLAsset)?.url == url { return }
        let p = AVPlayer(url: url)
        p.isMuted = muted
        player = p
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        // 一集播完自动重播，保持画面一直在动
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
        if isActive { p.play() }
    }

    private func togglePlay(_ p: AVPlayer) {
        if p.timeControlStatus == .playing { p.pause() } else { p.play() }
    }
}

// MARK: - 推荐流

struct FeedView: View {
    @StateObject private var model = FeedModel()
    @State private var index = 0
    @State private var open: FeedItem?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if model.loading {
                    ProgressView("正在准备推荐…").tint(.pink)
                } else if let e = model.error {
                    CompatUnavailable("加载失败", systemImage: "wifi.slash", desc: e)
                } else {
                    pager(geo)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .task { if model.items.isEmpty { await model.load() } }
        .sheet(item: $open) { it in
            NavigationStack { DetailView(series: it.series) }
        }
    }

    /// 用旋转把水平 TabView 变成垂直翻页（iOS 16 可用）
    private func pager(_ geo: GeometryProxy) -> some View {
        TabView(selection: $index) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, it in
                FeedCard(item: it, isActive: i == index) {
                    open = it
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .rotationEffect(.degrees(-90))
                .tag(i)
            }
        }
        .frame(width: geo.size.height, height: geo.size.width)
        .rotationEffect(.degrees(90), anchor: .topLeading)
        .offset(x: geo.size.width)
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: index) { i in model.prepare(i) }
        .onAppear { model.prepare(0) }
    }
}