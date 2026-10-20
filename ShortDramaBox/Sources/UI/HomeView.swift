import SwiftUI

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
                        Text(sec.name).font(.headline).padding(.horizontal)
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

struct BrowseView: View {
    @State private var slug = "real-drama"
    @State private var items: [Series] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 14) {
                    ForEach(items) { s in
                        NavigationLink { DetailView(series: s) } label: { PosterCard(series: s, width: 110) }
                            .buttonStyle(.plain)
                    }
                }.padding()
            }
            .navigationTitle("分类")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu(Catalog.categories.first { $0.slug == slug }?.name ?? "分类") {
                        ForEach(Catalog.categories, id: \.slug) { c in
                            Button(c.name) { slug = c.slug; Task { await load() } }
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .task(id: slug) { await load() }
        }
    }

    private func load() async {
        loading = true
        items = (try? await Catalog.category(slug)) ?? []
        loading = false
    }
}
