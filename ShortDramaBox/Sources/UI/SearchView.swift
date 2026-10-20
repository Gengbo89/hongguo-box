import SwiftUI

/// 搜索 = 站内服务端搜索（`/search/<关键词>`，按站方相关度排序）＋ 本地索引兜底。
/// 本地索引只有千余部，站内搜索覆盖全库，两者合并去重后才不会"很多都搜不到"。
/// 同名各季是独立剧集（标题带「第N季」），站内搜索会把它们一起返回。
struct SearchView: View {
    @State private var q = ""
    @State private var pool: [Series] = []
    @State private var loading = true
    @State private var progressText = "准备中…"
    @State private var seen = Set<String>()

    @State private var remote: [Series] = []      // 站内搜索结果
    @State private var remoteTotal = 0
    @State private var remoteNote = ""
    @State private var remoteTask: Task<Void, Never>?

    private var results: [Series] {
        let k = q.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return [] }
        var out: [Series] = []
        var ids = Set<String>()
        for s in remote where ids.insert(s.id).inserted { out.append(s) }
        for s in pool where s.title.localizedCaseInsensitiveContains(k) && ids.insert(s.id).inserted {
            out.append(s)
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if q.trimmingCharacters(in: .whitespaces).isEmpty {
                    if loading && pool.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(progressText).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    } else {
                        CompatUnavailable("搜索短剧", systemImage: "magnifyingglass",
                                          desc: "输入片名，直接搜站内全库\n本地已索引 \(pool.count) 部作为补充")
                    }
                } else if results.isEmpty {
                    VStack(spacing: 10) {
                        if remoteNote.isEmpty { ProgressView() }
                        Text(remoteNote.isEmpty ? "正在搜索…" : remoteNote)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 14) {
                            ForEach(results) { s in
                                NavigationLink { DetailView(series: s) } label: { PosterCard(series: s, width: 110) }
                                    .buttonStyle(.plain)
                            }
                        }.padding()
                    }
                    .safeAreaInset(edge: .top) { noteBar }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $q, prompt: "输入片名")
            .onChange(of: q) { v in scheduleRemote(v) }
            .task { await runIndex() }
        }
    }

    private var noteBar: some View {
        VStack(spacing: 2) {
            if !remoteNote.isEmpty {
                Text(remoteNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if loading {
                Text(progressText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 5)
        .background(.ultraThinMaterial)
    }

    private func add(_ list: [Series]) {
        for s in list where !s.id.isEmpty && seen.insert(s.id).inserted { pool.append(s) }
    }

    /// 输入停顿 300ms 后请求站内搜索，避免逐字打字打爆接口
    @MainActor
    private func scheduleRemote(_ raw: String) {
        remoteTask?.cancel()
        let key = raw.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            remote = []; remoteTotal = 0; remoteNote = ""; return
        }
        remoteNote = ""
        remoteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let p = try await SearchAPI.remote(key)
                guard !Task.isCancelled else { return }
                remote = p.list
                remoteTotal = p.total
                let extra = results.count - p.list.count
                remoteNote = "站内命中 \(p.total) 部" + (extra > 0 ? " · 本地索引补充 \(extra) 部" : "")
            } catch {
                guard !Task.isCancelled else { return }
                remote = []; remoteTotal = 0
                remoteNote = "站内搜索失败，仅用本地索引"
            }
        }
    }

    private func runIndex() async {
        if let c = Catalog.loadIndexCache() {
            add(c.list)
            loading = false
            let h = Int(c.age / 3600)
            progressText = "本地索引 \(pool.count) 部（\(h < 1 ? "刚刚" : "\(h) 小时前")）"
            if c.age < 60 * 60 * 6 { return }
        } else {
            loading = true
        }

        if let h = try? await Catalog.home() { add(h.flatMap(\.items)) }
        progressText = "本地索引 \(pool.count) 部…"

        let perCat = 12
        for c in Catalog.categories {
            for p in 1...perCat {
                guard let list = try? await Catalog.category(c.slug, page: p), !list.isEmpty else { break }
                let before = pool.count
                add(list)
                progressText = "\(c.name) \(p)/\(perCat) · 本地索引 \(pool.count) 部"
                if pool.count == before && p > 1 { break }
            }
        }
        progressText = "本地索引 \(pool.count) 部"
        loading = false
        Catalog.saveIndexCache(pool)
    }
}

struct HistoryView: View {
    @ObservedObject private var store = WatchStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    CompatUnavailable("暂无观看记录", systemImage: "clock", desc: "播放后会自动记录进度")
                } else {
                    List {
                        ForEach(store.items) { it in
                            NavigationLink {
                                DetailView(series: Series(id: it.seriesId, title: it.title, cover: it.cover))
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: URL(string: it.cover)) { $0.resizable().aspectRatio(contentMode: .fill) }
                                        placeholder: { Rectangle().fill(Color.white.opacity(0.1)) }
                                        .frame(width: 46, height: 62).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(it.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text("看到第 \(it.episode) 集 · \(Int(it.seconds / 60)) 分 \(Int(it.seconds) % 60) 秒")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { idx in
                            for i in idx where i < store.items.count {
                                store.remove(seriesId: store.items[i].seriesId)
                            }
                        }
                    }
                }
            }
            .navigationTitle("观看记录")
        }
    }
}
