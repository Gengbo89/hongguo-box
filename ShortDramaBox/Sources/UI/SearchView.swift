import SwiftUI

/// 站内搜索为客户端渲染，故本地建立索引后过滤。
/// 索引来源：首页 + 各频道多页（每页约 24 部），可达近千部。
struct SearchView: View {
    @State private var q = ""
    @State private var pool: [Series] = []
    @State private var loading = true
    @State private var progressText = "准备中…"
    @State private var seen = Set<String>()

    private var results: [Series] {
        let k = q.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return [] }
        // 列表接口不返回 tags，因此只按片名匹配
        return pool.filter { $0.title.localizedCaseInsensitiveContains(k) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && pool.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(progressText).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                } else if q.isEmpty {
                    ContentUnavailableView("搜索短剧", systemImage: "magnifyingglass",
                                           description: Text(loading
                                               ? "已索引 \(pool.count) 部，仍在继续…\n\(progressText)"
                                               : "已索引 \(pool.count) 部，输入片名"))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: q)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 14) {
                            ForEach(results) { s in
                                NavigationLink { DetailView(series: s) } label: { PosterCard(series: s, width: 110) }
                                    .buttonStyle(.plain)
                            }
                        }.padding()
                    }
                    .safeAreaInset(edge: .top) {
                        if loading {
                            Text(progressText)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(.ultraThinMaterial)
                        }
                    }
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $q, prompt: "输入片名")
            .task { await runIndex() }
        }
    }

    private func add(_ list: [Series]) {
        for s in list where !s.id.isEmpty && seen.insert(s.id).inserted { pool.append(s) }
    }

    private func runIndex() async {
        loading = true
        // 首页先出，让用户立刻能搜到热播
        if let h = try? await Catalog.home() { add(h.flatMap(\.items)) }
        progressText = "已索引 \(pool.count) 部…"

        let perCat = 12
        let total = Catalog.categories.count * perCat
        var done = 0
        for c in Catalog.categories {
            for p in 1...perCat {
                guard let list = try? await Catalog.category(c.slug, page: p), !list.isEmpty else {
                    done += (perCat - p + 1); break
                }
                let before = pool.count
                add(list)
                done += 1
                progressText = "\(c.name) \(p)/\(perCat) · 已索引 \(pool.count) 部（\(done * 100 / max(total,1))%）"
                if pool.count == before && p > 1 { done += (perCat - p); break }
            }
        }
        progressText = "已索引 \(pool.count) 部"
        loading = false
    }
}

struct HistoryView: View {
    @ObservedObject private var store = WatchStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView("暂无观看记录", systemImage: "clock", description: Text("播放后会自动记录进度"))
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
