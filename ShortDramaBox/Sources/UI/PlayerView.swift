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
    /// 每集源站给的全部档位（一条都不过滤），key 是集号
    @State private var availableOf: [Int: [VideoTrack]] = [:]
    @State private var preferredQuality: String? = nil

    init(series: Series, episodes: [Episode], start: Episode) {
        self.series = series; self.episodes = episodes; _current = State(initialValue: start)
        _scrolledID = State(initialValue: start.index)
    }

    var body: some View {
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
                            onTracks: { list in availableOf[ep.index] = list },
                            onEnded: {
                                // 播完自动跳下一集（页面会跟着滑过去）
                                if let nxt = episodes.first(where: { $0.index == ep.index + 1 }) {
                                    current = nxt
                                    scrolledID = nxt.index
                                }
                            }
                        )
                        // 之前用 GeometryReader 的 geo.size 定页面尺寸：GeometryReader
                        // 量到的是「安全区内」的高度，而下面滚动区 .ignoresSafeArea()
                        // 铺到整屏，两者对不上 —— 每页都比可视区矮一截，
                        // 分页错位、画面被推出屏幕，就是「出画」和「比例不对」。
                        // containerRelativeFrame 直接取滚动容器的尺寸，天然对齐。
                        .containerRelativeFrame([.horizontal, .vertical])
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

                Section {
                    let list = availableOf[current.index] ?? []
                    if list.isEmpty {
                        Text("正在解析…").foregroundStyle(.secondary).font(.footnote)
                    } else {
                        // 列出源站给的全部档位，一条都不过滤；
                        // 本机解不了的编码标注「本机转码」，选中后本地补齐
                        ForEach(list, id: \.self) { t in
                            Button {
                                preferredQuality = t.definition
                            } label: {
                                HStack(spacing: 8) {
                                    Text(t.definition)
                                    sourceBadge(for: t)
                                    Spacer()
                                    if qualityOf[current.index] == t.definition {
                                        Image(systemName: "checkmark").foregroundStyle(.pink)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("清晰度")
                } footer: {
                    Text("「本机转码」= 源站这一档是 bytevc2，iOS 没有对应解码器，"
                         + "改由本机把可解码的源档转成这个分辨率；第一次播会慢几秒，之后走缓存。")
                        .font(.footnote)
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

    /// 档位来源标记：本机转码 / 公开明文源
    @ViewBuilder
    /// 当前这一集正在播的档位所带的降级说明（正常档位为空串）
    private var playNote: String {
        let list = availableOf[current.index] ?? []
        let def = qualityOf[current.index]
        if let t = list.first(where: { $0.definition == def && !$0.note.isEmpty }) { return t.note }
        return list.first(where: { !$0.note.isEmpty })?.note ?? ""
    }

    private func sourceBadge(for t: VideoTrack) -> some View {
        if PlayerAPI.needsTranscode(t) {
            Text("本机转码")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.orange.opacity(0.18))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        } else if t.spadeA.isEmpty {
            Text("明文源")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.green.opacity(0.18))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        }
    }
}

// MARK: - 单集页面（自己管自己的播放器）

/// 长按加速的状态盒。必须是引用类型：手势闭包捕获的是 @State 的值快照，
/// body 一重算就可能拿到旧的那份，恢复倍速那一步会被静默跳过。
private final class BoostBox {
    var on = false
    var base: Float = 1.0
}

#if os(iOS)
/// 播放区手势层（UIKit 实现）。
///
/// 为什么不用 SwiftUI 的 onLongPressGesture：LongPressGesture 是
/// 「按住到 minimumDuration 就算完成」的**离散**手势，一旦完成，
/// 松手时不会再回调 onPressingChanged(false)。实测表现就是
/// 长按加速生效、松手却回不到 1x，要再摸一下屏幕才恢复。
/// UILongPressGestureRecognizer 的 .began / .ended / .cancelled
/// 才精确对应「按下」和「抬起」，被打断（来电、切后台）也能收到。
///
/// 不抢分页滚动：cancelsTouchesInView = false 且允许与其它手势同时识别；
/// 手指在 0.25 秒内移动超过 30 点时长按直接失败，翻页照常。
struct PlayerGestureLayer: UIViewRepresentable {
    /// 参数 = 这一下是不是点在视频下方（下三分之一）
    var onTap: (Bool) -> Void
    var onHoldStart: () -> Void
    var onHoldEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let hold = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 30
        hold.cancelsTouchesInView = false
        hold.delegate = context.coordinator
        v.addGestureRecognizer(hold)

        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.delegate = context.coordinator
        // 长按成立时不要再补一次「暂停」
        tap.require(toFail: hold)
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // body 每次重算闭包都会变，跟着刷新，免得回调打到旧状态上
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureLayer
        init(_ p: PlayerGestureLayer) { parent = p }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: parent.onHoldStart()
            case .ended, .cancelled, .failed: parent.onHoldEnd()
            default: break
            }
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let v = g.view else { return }
            // 下三分之一算「视频下方区域」：那里点一下是露出进度条，不是暂停
            let bottom = g.location(in: v).y > v.bounds.height * 0.7
            parent.onTap(bottom)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#else
/// 本机（macOS）typecheck 用的空壳；真机走上面的 UIKit 版本。
struct PlayerGestureLayer: View {
    var onTap: (Bool) -> Void
    var onHoldStart: () -> Void
    var onHoldEnd: () -> Void
    var body: some View { Color.clear }
}
#endif

private struct EpisodePage: View {
    let series: Series
    let episode: Episode
    let isActive: Bool
    let speed: Float
    let forceQuality: String?
    var onQuality: (String) -> Void
    var onTracks: ([VideoTrack]) -> Void
    var onEnded: () -> Void

    @State private var player: AVPlayer?
    @State private var tracks: [VideoTrack] = []
    @State private var status = "准备中…"
    @State private var progress: Double = 0
    @State private var ready = false
    @State private var timeObs: Any?
    /// 进度条专用的时间观察（0.3 秒一次；上面那个 5 秒的只管写观看记录）
    @State private var scrubObs: Any?
    /// 当前播放位置（秒）
    @State private var position: Double = 0
    /// 这一集总时长（秒），0 表示还不知道
    @State private var duration: Double = 0
    /// 正在拖进度条
    @State private var scrubbing = false
    /// 开始拖动前是不是在播，松手后要接着播
    @State private var wasPlaying = false
    /// 进度条是否露出（默认藏着，点视频下方才出来）
    @State private var showBar = false
    /// 露出 3 秒后自动收起
    @State private var hideTask: Task<Void, Never>?
    @State private var endObs: NSObjectProtocol?
    @State private var started = false
    @State private var failed = false
    /// 画面填充模式（0 自动 / 1 铺满 / 2 适应），与推荐页共用
    @AppStorage("video_fit_mode") private var fitMode = 0
    /// 当前这一集的片源尺寸，交给自动判定是否该铺满
    @State private var videoSize: CGSize = .zero
    /// 短按暂停
    @State private var paused = false
    /// 长按快进中
    @State private var boosting = false
    /// 长按加速的权威状态（引用类型，闭包读到的永远是当前值）
    @State private var boost = BoostBox()

    /// 长按快进的倍速
    private static let boostRate: Float = 2.0

    /// 盯 AVPlayerItem 的失败（解码器报错 / 播到一半中断）
    @State private var itemObs: NSKeyValueObservation?
    @State private var failObs: NSObjectProtocol?
    /// 本地文件不需要缓冲，迟迟不出画面就是坏了
    @State private var watchdog: Task<Void, Never>?
    /// 这一集已经自动重试过一次；再失败就摆按钮让用户点
    @State private var autoRetried = false
    @State private var retrying = false
    /// 本页上次播到的位置。滑走时 onDisappear 会把播放器拆掉，
    /// 靠它回来才能接上，而不是退回几秒或者从头开始。
    @State private var lastPosition: Double = 0

    var body: some View {
        ZStack {
            Color.black
            if let p = player, ready {
                // 与推荐页同一套渲染：AVPlayerLayer + 自定 videoGravity。
                // VideoPlayer 自带控制条、尺寸算法也不一样，
                // 两处画面表现不一致，正是「每个播放的地方都不对」的一部分。
                Color.clear.overlay {
                    PlayerLayerView(player: p,
                                    fill: VideoFit.forced(fitMode),
                                    videoSize: videoSize)
                }

                // 手势层：短按暂停/继续，长按住 2x 加速、松手恢复原倍速。
                // 用 onLongPressGesture 而不是 DragGesture(minimumDistance:0)：
                // 后者套在分页 ScrollView 里容易和翻页抢手势，
                // maximumDistance 让手指挪超过 30 点就直接交给翻页。
                PlayerGestureLayer(
                    onTap: { bottom in
                        if bottom { toggleBar() } else { togglePlay() }
                    },
                    onHoldStart: { beginBoost() },
                    onHoldEnd: { endBoost() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 注意：下面两块**不能**写成 if paused { } / if boosting { }。
                // 条件插入/移除子视图会让 SwiftUI 重建这个手势，
                // 「松手」回调于是落到改之前那个闭包上 —— 里面状态还是旧值，
                // 恢复被跳过，倍速就卡在 1.5x 回不来。
                // 固定视图树、只改透明度，手势实例就不会被换掉。

                Image(systemName: "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 12)
                    .allowsHitTesting(false)
                    .opacity(paused ? 1 : 0)
                VStack {
                    Text(String(format: "%gx 加速中", Self.boostRate))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(.top, 64)
                    Spacer()
                }
                .allowsHitTesting(false)
                .opacity(boosting ? 1 : 0)

                // 取流降级提示：官方接口没给出高清档位时，把原因常驻在画面上。
                // 用户有权知道「为什么只有 360p」，而不是默默变糊。
                if !playNote.isEmpty {
                    VStack {
                        Text("⚠️ " + playNote)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.orange.opacity(0.72))
                            .clipShape(Capsule())
                            .padding(.top, 96)
                            .padding(.horizontal, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                // 进度条：默认藏着（不挡画面），点视频下方才露出，3 秒后自动收起。
                // 不给它上 if：视图树保持恒定，只改透明度和是否可点。
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Text(Self.clock(position))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 46, alignment: .trailing)
                        ScrubBar(
                            position: position,
                            duration: duration,
                            onEditing: { editing in
                                if editing {
                                    scrubbing = true
                                    wasPlaying = (player?.rate ?? 0) > 0
                                    player?.pause()
                                    hideTask?.cancel()
                                } else {
                                    let t = CMTime(seconds: position, preferredTimescale: 600)
                                    player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                                    scrubbing = false
                                    if wasPlaying {
                                        player?.play()
                                        player?.rate = boosting ? Self.boostRate : speed
                                    }
                                    // 拖完再给 3 秒
                                    armHide()
                                }
                            },
                            onSeek: { sec in position = sec })
                        Text(Self.clock(duration))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 46, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .padding(.top, 8)
                    .background(
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
                .opacity(showBar ? 1 : 0)
                .allowsHitTesting(showBar)
                .animation(.easeOut(duration: 0.22), value: showBar)
            } else {
                VStack(spacing: 14) {
                    if failed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30)).foregroundStyle(.orange)
                        Text(status)
                            .font(.footnote).foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        // 兜底：不用退回选集页再点进来，这里直接丢掉缓存重下这一集
                        Button {
                            Task { await reload() }
                        } label: {
                            Label(retrying ? "正在重新加载…" : "重新加载",
                                  systemImage: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(.white.opacity(0.14))
                                .clipShape(Capsule())
                        }
                        .disabled(retrying)
                        Text("上下滑动换一集").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    } else {
                        ProgressView(value: progress).tint(.pink).frame(width: 220)
                        Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .onChange(of: isActive) { act in
            if act { Task { await start() } } else { player?.pause(); paused = false }
        }
        .onChange(of: speed) { s in
            // 换倍速时如果还在长按加速，先退出，免得恢复成旧值
            endBoost()
            applySpeed(s)
        }
        .onChange(of: paused) { p in if p { endBoost() } }
        .onChange(of: forceQuality) { _ in
            // 换清晰度：重新拉这一集
            if isActive, forceQuality != nil { Task { await start(force: true) } }
        }
        .onAppear { if isActive { Task { await start() } } }
        .onDisappear { cleanup() }
    }

    /// 盯住这一集的 AVPlayerItem
    private func watchItem(_ p: AVPlayer) {
        stopWatching()
        guard let item = p.currentItem else { return }
        itemObs = item.observe(\.status, options: [.initial, .new]) { it, _ in
            guard it.status == .failed else { return }
            let why = it.error?.localizedDescription ?? "解码失败"
            Task { @MainActor in playbackFailed(why) }
        }
        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { n in
                let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in playbackFailed(e?.localizedDescription ?? "播放中断") }
            }
        // 本地文件不用缓冲：12 秒还不出画面就是这一集有问题
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, ready, !paused, let pl = player else { return }
            // 已经出过画面、或者正在播，就不算卡住（CMTime 不能直接和 0 比）
            let secs = pl.currentTime().seconds
            let produced = secs.isFinite && secs > 0
            guard !produced, pl.timeControlStatus != .playing else { return }
            playbackFailed("一直没有画面")
        }
    }

    private func stopWatching() {
        itemObs?.invalidate(); itemObs = nil
        if let o = failObs { NotificationCenter.default.removeObserver(o); failObs = nil }
        watchdog?.cancel(); watchdog = nil
    }

    /// 这一集播不出来。先自动丢缓存重下一次；再不行才摆出「重新加载」让用户点。
    /// 以前这里什么都不做：坏文件会一直被 existing() 当成缓存命中，
    /// 这一集就永远是坏的，只能退出去重进。
    private func playbackFailed(_ why: String) {
        guard !retrying else { return }
        stopWatching()
        player?.pause()
        player = nil
        ready = false
        if !autoRetried {
            autoRetried = true
            status = "这一集解码失败，正在重新加载…（\(why)）"
            Task { await reload() }
        } else {
            failed = true
            status = "这一集加载不出来：\(why)"
        }
    }

    /// 丢掉这一集的成品缓存（含转码结果）再整条重来
    private func reload() async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
        for t in tracks {
            MediaStore.invalidate(vid: episode.vid, definition: t.definition)
            if let r = MediaStore.rendition(for: t) {
                Transcoder.invalidate(
                    source: MediaStore.cachedPath(vid: episode.vid,
                                                  definition: t.definition),
                    rendition: r)
            }
        }
        await start(force: true)
    }

    private func togglePlay() {
        guard let p = player else { return }
        if p.timeControlStatus == .playing {
            p.pause()
            paused = true
        } else {
            // 播完之后再点，从头开始
            let dur = p.currentItem?.duration ?? .zero
            if dur.isNumeric,
               CMTimeGetSeconds(p.currentTime()) >= CMTimeGetSeconds(dur) - 0.4 {
                p.seek(to: .zero)
            }
            p.play()
            if speed != 1.0 { p.rate = speed }
            paused = false
        }
    }

    /// 开始长按加速：记下原倍速，再抬到加速倍速。
    private func beginBoost() {
        // 用自己记的暂停状态判断，不看 timeControlStatus：
        // 缓冲、seek 的时候它不是 .playing，长按就会没反应
        // ——之前「长按不好用」就是这个原因。
        // 已经暂停时不进快进，免得一按反而播起来。
        guard let p = player, !paused else { return }
        boost.base = speed
        boost.on = true
        boosting = true
        p.rate = Self.boostRate
    }

    /// 结束长按加速、恢复原倍速。可重复调用（不在加速中就是空操作）。
    private func endBoost() {
        guard boost.on else { return }
        boost.on = false
        boosting = false
        player?.rate = boost.base
    }

    /// 点视频下方：露出进度条；再点一下收起
    private func toggleBar() {
        if showBar {
            hideTask?.cancel(); hideTask = nil
            withAnimation(.easeOut(duration: 0.22)) { showBar = false }
        } else {
            withAnimation(.easeOut(duration: 0.22)) { showBar = true }
            armHide()
        }
    }

    /// 3 秒后自动收起（拖动中不收起）
    private func armHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !scrubbing else { return }
            withAnimation(.easeOut(duration: 0.22)) { showBar = false }
        }
    }

    /// 自绘进度条。
///
/// 不用 SwiftUI 的 Slider：iOS 上不给改 thumb 尺寸，那个圆点太大。
/// 自己画一个：3pt 轨道 + 9pt 圆点，点一下定位、按住拖也能定位。
private struct ScrubBar: View {
    let position: Double
    let duration: Double
    /// 开始/结束拖动
    let onEditing: (Bool) -> Void
    /// 拖到某个位置（秒）
    let onSeek: (Double) -> Void

    @State private var dragging = false

    private let knob: CGFloat = 9
    private let track: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let frac = duration > 0 ? min(max(position / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                    .frame(height: track)
                Capsule().fill(.pink)
                    .frame(width: w * frac, height: track)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: min(max(w * frac - knob / 2, 0), w - knob))
            }
            .frame(maxHeight: .infinity)
            // 触摸区拉高一点，好拖（视觉上还是细的）
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; onEditing(true) }
                        onSeek(min(max(v.location.x / w, 0), 1) * duration)
                    }
                    .onEnded { v in
                        onSeek(min(max(v.location.x / w, 0), 1) * duration)
                        dragging = false
                        onEditing(false)
                    }
            )
        }
        .frame(height: 22)
    }
}

/// 秒 → mm:ss（超过一小时用 h:mm:ss）
    private static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func applySpeed(_ s: Float) {
        player?.defaultRate = s
        if player?.timeControlStatus == .playing { player?.rate = s }
    }

    private func cleanup() {
        PlaybackCenter.shared.release("ep:\(episode.vid)")
        // 拆播放器之前记住播到哪了，滑回来接着放
        if let p = player {
            let sec = p.currentTime().seconds
            if sec.isFinite, sec > 0 { lastPosition = sec }
        }
        stopWatching()
        endBoost()
        boosting = false; paused = false
        hideTask?.cancel(); hideTask = nil
        if let o = timeObs { player?.removeTimeObserver(o); timeObs = nil }
        if let o = scrubObs { player?.removeTimeObserver(o); scrubObs = nil }
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        player?.pause(); player = nil
    }

    /// 选定要播的档位。
    /// - 手动指定清晰度时，**不做任何编解码过滤** —— 源站给了就认，播不了交给本机转码
    /// - 自动选择时优先能直接播的最高清晰度（省掉转码等待）
    /// 传入的 list 已按清晰度从高到低排好。
    private static func pick(_ list: [VideoTrack], force: String?) -> VideoTrack? {
        if let f = force, let t = list.first(where: { $0.definition == f }) { return t }
        let ok = PlayerAPI.playable(list)
        if let p = ok.first(where: { $0.definition.contains("1080") }) { return p }
        if let f = ok.first { return f }
        // 一条都直接播不了：挑最高清晰度并本机转码
        return list.first
    }

    private func start(force: Bool = false) async {
        // 播放器还在：直接续上。
        //
        // 这里原来只判断 `started`，但 cleanup()（onDisappear）会把 player 置空。
        // 滑走再滑回来、或者自动下一集后往回滑，started 仍是 true，
        // 于是这里直接 return —— 播放器再也没被建出来，画面永远是「准备中」。
        // 现象就是「某一集解码不出来，退回选集页重进才好」。
        if started && !force, let p = player {
            applySpeed(speed)
            if !paused { p.play() }
            return
        }
        started = true
        autoRetried = false
        failed = false
        ready = false; progress = 0; status = "获取播放地址…"
        duration = 0; position = 0; scrubbing = false
        showBar = false; hideTask?.cancel(); hideTask = nil
        if let o = timeObs { player?.removeTimeObserver(o); timeObs = nil }
        if let o = scrubObs { player?.removeTimeObserver(o); scrubObs = nil }
        player?.pause(); player = nil

        do {
            if tracks.isEmpty {
                // 取全部档位：一条都不过滤，播不了的留到后面本机转码
                tracks = await PlayerAPI.allTracks(for: episode.vid)
                if tracks.isEmpty {
                    status = "该集暂无可用片源"; failed = true; return
                }
            }
            onTracks(tracks)
            guard let best = Self.pick(tracks, force: forceQuality) else {
                status = "无可用清晰度"; failed = true; return
            }
            onQuality(best.definition)
            // 接口给的尺寸：横屏片源靠它避开「被截一条铺满屏幕」
            videoSize = CGSize(width: best.width, height: best.height)
            let transcoding = PlayerAPI.needsTranscode(best)

            let url = try await MediaStore.prepareForPlayback(
                vid: episode.vid, track: best, pool: tracks) { p in
                Task { @MainActor in
                    progress = p
                    let pct = Int(p * 100)
                    status = transcoding
                        ? "本机转码 \(best.definition) \(pct)%"
                        : "下载并解密中 \(pct)%"
                }
            }
            let p = AVPlayer(url: url)
            p.defaultRate = speed
            player = p
            // 一建好就盯上：解码器报错、播到一半中断、迟迟不出画面，
            // 都要能自己爬起来，而不是留一块黑屏让人退出去重进
            watchItem(p)

            // 续播：本页上次的位置优先（滑走再回来接得上），
            // 其次是观看记录（退出去重进接得上）
            var at = lastPosition
            if at <= 3 {
                at = WatchStore.shared.progress(seriesId: series.id)
                    .flatMap { $0.episode == episode.index ? $0.seconds : nil } ?? 0
            }
            if at > 3 {
                await p.seek(to: CMTime(seconds: at, preferredTimescale: 600))
            }
            // 申请全局播放权：进播放页时把推荐页底下那张卡片停掉，
            // 否则两个画面同时出声。
            PlaybackCenter.shared.claim("ep:\(episode.vid)") { [weak p] in p?.pause() }
            p.play()
            if speed != 1.0 { p.rate = speed }
            paused = false
            ready = true

            timeObs = p.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { t in
                let sec = CMTimeGetSeconds(t)
                guard sec.isFinite, sec > 0 else { return }
                WatchStore.shared.record(seriesId: series.id, title: series.title,
                                         cover: series.cover, episode: episode.index, seconds: sec)
            }

            // 进度条：0.3 秒刷一次当前位置和总时长
            if let o = scrubObs { p.removeTimeObserver(o); scrubObs = nil }
            scrubObs = p.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main) { t in
                let sec = CMTimeGetSeconds(t)
                let d = p.currentItem?.duration.seconds ?? 0
                Task { @MainActor in
                    if d.isFinite, d > 0 { duration = d }
                    if !scrubbing, sec.isFinite { position = sec }
                }
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