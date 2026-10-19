import SwiftUI

/// 站内搜索为客户端渲染，故本地建立索引后过滤
struct SearchView: View {
    @State private var q = ""
    @State private var pool: [Series] = []
    @State private var loading = true

    private var results: [Series] {
        let k = q.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return [] }
        return pool.filter { $0.title.localizedCaseInsensitiveContains(k) || $0.tags.contains { $0.contains(k) } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("建立索引…") }
                else if q.isEmpty {
                    ContentUnavailableView("搜索短剧", systemImage: "magnifyingglass",
                                           description: Text("已索引 \(pool.count) 部，输入片名或标签"))
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
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $q, prompt: "片名 / 标签")
            .task { await buildIndex() }
        }
    }

    private func buildIndex() async {
        loading = true
        var seen = Set<String>(); var out: [Series] = []
        func add(_ list: [Series]) { for s in list where !s.id.isEmpty && seen.insert(s.id).inserted { out.append(s) } }
        if let h = try? await Catalog.home() { add(h.flatMap(\.items)) }
        for c in Catalog.categories { if let l = try? await Catalog.category(c.slug) { add(l) } }
        pool = out
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
