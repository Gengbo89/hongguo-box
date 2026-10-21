import SwiftUI

/// 首页区块 -> 站内频道 slug。
///
/// 首页每个区块只给 9 条，想看全得去 /category/<slug> 按页拉。
/// tab_type 是站内短名（all/human/comic/ai），和 slug 不是一套命名，
/// 所以名称也对一遍，站点改名也不会静默走到错频道。
extension HomeSection {
    var channelSlugs: [String] {
        switch id {
        case "human": return ["real-drama"]
        case "comic": return ["comic-drama"]
        case "ai":    return ["ai-drama"]
        // 「热播短剧」= 三种短剧频道合起来（漫画不算短剧）
        case "all":   return ["real-drama", "comic-drama", "ai-drama"]
        default:
            if name.contains("真人") { return ["real-drama"] }
            if name.contains("漫剧") { return ["comic-drama"] }
            if name.contains("漫画") { return ["comic"] }
            if name.uppercased().contains("AI") { return ["ai-drama"] }
            return ["real-drama", "comic-drama", "ai-drama"]
        }
    }
}

struct HomeView: View {
    @State private var sections: [HomeSection] = []
    @State private var err: String?
    @State private var loading = true
    @State private var showAbout = false

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView("加载中…") }
                else if let e = err { CompatUnavailable("加载失败", systemImage: "wifi.slash", desc: e) }
                else { list }
            }
            .navigationTitle("短剧盒子")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAbout = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .task { await load() }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(sections) { sec in
                    VStack(alignment: .leading, spacing: 8) {
                        // 标题行：右边「查看更多」进频道分页，不再只给 9 条
                        HStack(alignment: .firstTextBaseline) {
                            Text(sec.name).font(.headline)
                            Spacer()
                            NavigationLink {
                                ChannelGridView(title: sec.name, slugs: sec.channelSlugs)
                            } label: {
                                HStack(spacing: 2) {
                                    Text("查看更多")
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(sec.items) { s in
                                    NavigationLink { DetailView(series: s) } label: { PosterCard(series: s) }
                                        .buttonStyle(.plain)
                                }
                            }.padding(.horizontal)
                        }
                    }
                }
            }.padding(.vertical)
        }
    }

    private func load() async {
        loading = true; err = nil
        do {
            let s = try await Catalog.home()
            sections = s
            if s.isEmpty { err = "暂无数据" }
        } catch { err = "\(error)" }
        loading = false
    }
}

/// 按频道分页浏览，滚到底自动续下一页。
///
/// 首页每个区块只有 9 条、站内单页 24 条，想看全只能这样一页页翻。
/// 传多个 slug 时（「热播短剧」= 真人剧 + 漫剧 + AI剧）每翻一页各取一页再合并去重。
struct ChannelGridView: View {
    let title: String
    let slugs: [String]

    @State private var items: [Series] = []
    @State private var seen = Set<String>()
    @State private var page = 1
    @State private var loading = false
    @State private var finished = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { s in
                    NavigationLink { DetailView(series: s) } label: { PosterCard(series: s, width: 110) }
                        .buttonStyle(.plain)
                        .onAppear {
                            // 最后一张露面就去取下一页
                            if s.id == items.last?.id { Task { await more() } }
                        }
                }
            }.padding()

            Group {
                if loading { ProgressView().padding(.bottom, 24) }
                else if finished && !items.isEmpty {
                    Text("没有更多了").font(.footnote)
                        .foregroundStyle(.secondary).padding(.bottom, 24)
                } else if items.isEmpty && finished {
                    // 只在真的翻完一轮还是空的时候才说没内容，
                    // 否则第一次进页面会闪一下「暂无内容」
                    CompatUnavailable("暂无内容", systemImage: "tray",
                                       desc: "这个频道暂时没有可展示的剧集")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reset(); await more() }
        .task { await more() }
    }

    private func more() async {
        // 这个守卫在主 actor 上同步跑完，连点也只会进来一次
        guard !loading, !finished else { return }
        loading = true
        defer { loading = false }

        var added = 0
        for slug in slugs {
            guard let list = try? await Catalog.category(slug, page: page), !list.isEmpty else { continue }
            for s in list where !seen.contains(s.id) {
                seen.insert(s.id); items.append(s); added += 1
            }
        }
        if added == 0 { finished = true } else { page += 1 }
    }

    private func reset() {
        items = []; seen = []; page = 1; finished = false
    }
}

struct BrowseView: View {
    @State private var slug = "real-drama"

    var body: some View {
        NavigationStack {
            ChannelGridView(title: Catalog.categories.first { $0.slug == slug }?.name ?? "分类",
                            slugs: [slug])
                // 换频道就换一份新的分页状态，不要接着上一个频道的页码翻
                .id(slug)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu(Catalog.categories.first { $0.slug == slug }?.name ?? "分类") {
                            ForEach(Catalog.categories, id: \.slug) { c in
                                Button(c.name) { slug = c.slug }
                            }
                        }
                    }
                }
        }
    }
}