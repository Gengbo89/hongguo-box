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
    var series: Series
    var episode: Episode?
    /// 解析时顺手存下的全集列表，点画面时直接起播，不用再请求一次
    var episodes: [Episode] = []
    var track: VideoTrack?
    var status: Status = .pending
    var id: String { series.id }
}

// MARK: - 纯播放器视图
//
// 不用 SwiftUI 的 VideoPlayer：它自带一套控制层，放进分页容器里
// 会按自己的方式算尺寸，容易导致画面被裁或比例不对。
// 这里直接用 AVPlayerLayer，videoGravity 自己定，画面一定完整。
#if os(iOS)
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// true = 铺满（可能裁边）；false = 完整显示（可能有黑边）
    var fill: Bool = false

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }

    func updateUIView(_ v: PlayerHostView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ v: PlayerHostView, coordinator: ()) {
        v.playerLayer.player = nil
    }
}

final class PlayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    // 关键：UIKit 承载视图默认参与触摸，会吃掉上层 SwiftUI 按钮（选集等）的点击，
    // 表现就是"点了没反应"。播放器只负责画面，不接收任何手势。
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
    }
}
#else
/// 非 iOS（仅用于本机编译检查）
struct PlayerLayerView: View {
    let player: AVPlayer
    var fill: Bool = false
    var body: some View { Color.black }
}
#endif

// MARK: - 推荐流数据

@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    @Published private(set) var poolNote = ""

    private var inFlight: Set<String> = []
    private let prefetchAhead = 2

    /// 推荐池：优先用全量索引（几百上千部），没有就用首页那几十部
    func load() async {
        loading = true; error = nil
        var pool: [Series] = []
        var note = ""

        // 1) 本地全量索引（之前「分类」页建过就有）
        if let cached = Catalog.loadIndexCache() {
            pool = cached.list
            note = "全量片库 \(pool.count) 部"
        }

        // 2) 首页板块（一定有，作为保底/补充）
        var home: [Series] = []
        if let secs = try? await Catalog.home() { home = secs.flatMap { $0.items } }

        if pool.isEmpty {
            pool = home
            note = "首页推荐 \(pool.count) 部"
            // 首页太少就现场翻几页分类补齐
            if pool.count < 40 {
                for c in Catalog.categories {
                    if let more = try? await Catalog.category(c.slug, page: 1) { pool += more }
                    if pool.count >= 120 { break }
                }
                note = "首页+分类 \(pool.count) 部"
            }
        } else {
            // 索引里可能没有首页新上的，混进去
            pool += home
        }

        var seen = Set<String>()
        let uniq = pool.filter { seen.insert($0.id).inserted }
        guard !uniq.isEmpty else {
            error = "没有拿到推荐内容，检查下网络"
            loading = false
            return
        }
        items = uniq.shuffled().map { FeedItem(series: $0) }
        poolNote = note + "，随机播放"
        loading = false
    }

    /// 把离当前位置太远的待办丢掉，避免滑太久后一堆任务堆积
    func prepare(_ index: Int) {
        guard items.indices.contains(index) else { return }
        for k in index...(index + prefetchAhead) where items.indices.contains(k) {
            prepareOne(k)
        }
    }

    /// 从播放器回来后重新解析这一页，让它接着新进度播
    func refresh(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].status = .pending
        prepareOne(index)
    }

    private func prepareOne(_ i: Int) {
        guard items.indices.contains(i) else { return }
        switch items[i].status {
        case .ready, .downloading, .resolving: return
        case .pending, .failed: break
        }
        let item = items[i]
        if inFlight.contains(item.series.id) { return }
        inFlight.insert(item.series.id)
        items[i].status = .resolving

        Task { [weak self] in
            guard let self else { return }
            await self.resolve(i)
        }
    }

    private func resolve(_ i: Int) async {
        guard items.indices.contains(i) else { return }
        let series = items[i].series
        defer { inFlight.remove(series.id) }

        // 详情（拿集数）
        guard let (full, eps) = try? await Catalog.detail(series.id), !eps.isEmpty else {
            setStatus(i, .failed("暂无片源")); return
        }
        guard items.indices.contains(i) else { return }

        // 简介只有详情接口才有（内置索引里没存，省体积），补进这一页
        if items[i].series.intro.isEmpty, !full.intro.isEmpty {
            items[i].series.intro = full.intro
        }
        if items[i].series.episodeCount == 0 { items[i].series.episodeCount = full.episodeCount }

        // 优先从上次看到的那集接着播（记录里有就续播，否则随机）
        let ep: Episode
        if let h = WatchStore.shared.progress(seriesId: series.id),
           let match = eps.first(where: { $0.index == h.episode }) {
            ep = match
        } else {
            ep = eps.randomElement() ?? eps[0]
        }
        items[i].episode = ep
        items[i].episodes = eps

        // 取流：全部档位都要，播不了的留给本机转码
        let tracks = await PlayerAPI.allTracks(for: ep.vid)
        guard let best = Self.pick(tracks) else {
            setStatus(i, .failed("无可用清晰度")); return
        }
        guard items.indices.contains(i) else { return }
        items[i].track = best

        // 下载 + 解密（必要时本机转码）
        do {
            let url = try await MediaStore.prepareForPlayback(
                vid: ep.vid, track: best, pool: tracks) { p in
                Task { @MainActor in self.setStatus(i, .downloading(p)) }
            }
            guard items.indices.contains(i) else { return }
            setStatus(i, .ready(url))
        } catch {
            setStatus(i, .failed("加载失败"))
        }
    }

    /// 选档：优先能直接播的 1080p；一条都直接播不了就挑最高档走本机转码。
    /// 传入的 tracks 已按清晰度从高到低排好，一条都不过滤。
    static func pick(_ tracks: [VideoTrack]) -> VideoTrack? {
        let ok = PlayerAPI.playable(tracks)
        let list = ok.isEmpty ? tracks : ok
        if let p = list.first(where: { $0.definition.contains("1080") }) { return p }
        return list.first
    }

    private func setStatus(_ i: Int, _ s: FeedItem.Status) {
        guard items.indices.contains(i) else { return }
        items[i].status = s
    }
}

// MARK: - 单页

private struct FeedCard: View {
    let item: FeedItem
    let isActive: Bool
    var onPlay: () -> Void      // 点画面：接着上次进度播放
    var onDetail: () -> Void    // 右侧「选集」：进详情页

    @State private var player: AVPlayer?
    @State private var muted = false
    @State private var liked = false
    @State private var showQuality = false
    @State private var ended: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black

            // 封面（视频没准备好时铺底）
            AsyncImage(url: URL(string: item.series.cover)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else { Color.black }
            }
            .overlay(Color.black.opacity(player == nil ? 0.1 : 0.55))
            .clipped()

            if let p = player {
                PlayerLayerView(player: p, fill: true)
            } else {
                loadingOverlay
            }

            // 整屏可点：点画面任意处接着上次进度播放
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onPlay() }

            // 清晰度角标
            if let t = item.track, player != nil {
                VStack {
                    HStack {
                        Text("\(t.definition) · \(t.codec)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.45))
                            .clipShape(Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.leading, 14).padding(.top, 8)
                .allowsHitTesting(false)
            }

            // 右侧操作栏
            VStack(spacing: 20) {
                Button { liked.toggle() } label: {
                    sideIcon(liked ? "heart.fill" : "heart", "喜欢",
                             color: liked ? .pink : .white)
                }
                Button { muted.toggle(); player?.isMuted = muted } label: {
                    sideIcon(muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             muted ? "已静音" : "有声")
                }
                Button(action: onDetail) {
                    sideIcon("list.bullet", "选集")
                }
            }
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 底部信息
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let ep = item.episode {
                        Text("第 \(ep.index) 集")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.pink.opacity(0.85)).clipShape(Capsule())
                    }
                    Text("共 \(item.series.episodeCount) 集")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                }
                Text(item.series.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(2)
                if !item.series.intro.isEmpty {
                    Text(item.series.intro)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Text("上滑看下一部 · 点画面继续观看")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
            // 必须显式贴底：ZStack 默认垂直居中，只设 maxWidth 会让这块文字
            // 飘在屏幕中间挡住画面（简介尤其明显）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 260).frame(maxHeight: .infinity, alignment: .bottom)
            )
            .allowsHitTesting(false)
        }
        .clipped()
        .onChange(of: isActive) { active in
            if active { start() } else { player?.pause() }
        }
        .onChange(of: item.status) { _ in syncPlayer() }
        .onAppear { if isActive { start() } }
        .onDisappear { teardown() }
    }

    private func sideIcon(_ name: String, _ label: String, color: Color = .white) -> some View {
        VStack(spacing: 4) {
            Image(systemName: name).font(.system(size: 24)).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.white)
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            switch item.status {
            case .downloading(let p):
                ProgressView(value: p).tint(.pink).frame(width: 180)
                Text("解密中 \(Int(p * 100))%").font(.footnote).foregroundStyle(.white.opacity(0.85))
            case .failed(let m):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(m).font(.footnote).foregroundStyle(.white.opacity(0.85))
                Text("上滑看下一部").font(.caption2).foregroundStyle(.white.opacity(0.5))
            default:
                ProgressView().tint(.pink)
                Text("正在准备片源…").font(.footnote).foregroundStyle(.white.opacity(0.85))
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
        if let cur = player?.currentItem?.asset as? AVURLAsset, cur.url == url { return }
        teardown()
        let p = AVPlayer(url: url)
        p.isMuted = muted
        player = p
        // 一集播完回到开头重播，画面一直在动
        ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
        if isActive { p.play() }
    }

    private func teardown() {
        player?.pause()
        if let e = ended { NotificationCenter.default.removeObserver(e); ended = nil }
        player = nil
    }
}

// MARK: - 推荐流

/// 点画面要起播的目标（播放器需要全集列表 + 起始集）
private struct PlayTarget: Identifiable {
    let series: Series
    let episodes: [Episode]
    let start: Episode
    var id: String { series.id }
}

struct FeedView: View {
    @StateObject private var model = FeedModel()
    @State private var scrolledID: Int?
    @State private var open: FeedItem?
    @State private var play: PlayTarget?

    private var index: Int { scrolledID ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.loading {
                VStack(spacing: 10) {
                    ProgressView().tint(.pink)
                    Text("正在准备推荐…").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            } else if let e = model.error {
                CompatUnavailable("加载失败", systemImage: "wifi.slash", desc: e)
            } else {
                pager
            }
        }
        .task { if model.items.isEmpty { await model.load() } }
        // 右侧「选集」才进详情页
        .sheet(item: $open) { it in
            NavigationStack { DetailView(series: it.series) }
        }
        // 点画面直接接着进度播，不再绕一层详情页
        .fullScreenCover(item: $play, onDismiss: {
            let i = index
            guard model.items.indices.contains(i) else { return }
            let it = model.items[i]
            if let now = WatchStore.shared.progress(seriesId: it.series.id)?.episode,
               now != it.episode?.index {
                model.refresh(i)   // 只有换了集才重解析，免得白闪一下
            }
        }) { t in
            PlayerView(series: t.series, episodes: t.episodes, start: t.start)
        }
    }

    /// 点画面：接着上次进度起播。集列表在解析时就顺手存下来了，
    /// 万一是还没解析完就抢点，这里补一次请求。
    private func startPlay(_ i: Int) {
        guard model.items.indices.contains(i) else { return }
        let it = model.items[i]
        if !it.episodes.isEmpty {
            play = PlayTarget(series: it.series, episodes: it.episodes, start: resumeEpisode(it))
            return
        }
        Task {
            guard let (s, eps) = try? await Catalog.detail(it.series.id), !eps.isEmpty else { return }
            var filled = it
            filled.episodes = eps
            play = PlayTarget(series: s, episodes: eps, start: resumeEpisode(filled))
        }
    }

    /// 有观看记录就从记录那集开始，否则用这一页已经解析出的那集
    private func resumeEpisode(_ it: FeedItem) -> Episode {
        let want = WatchStore.shared.progress(seriesId: it.series.id)?.episode ?? it.episode?.index ?? 1
        return it.episodes.first { $0.index == want } ?? it.episodes[0]
    }

    /// 原生竖向分页：每页正好一屏。
    /// containerRelativeFrame 直接取滚动容器尺寸（不再手算 GeometryReader），
    /// 页面高度与可见区域严格一致，切页不会错位、比例不会怪。
    private var pager: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, it in
                    FeedCard(item: it, isActive: i == index,
                             onPlay: { startPlay(i) },
                             onDetail: { open = it })
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrolledID)
        .scrollIndicators(.hidden)
        .onChange(of: scrolledID) { v in if let v { model.prepare(v) } }
        .onAppear { model.prepare(0) }
        .overlay(alignment: .bottom) {
            if !model.poolNote.isEmpty {
                Text(model.poolNote)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, 2)
            }
        }
    }
}