import SwiftUI

struct DetailView: View {
    let series: Series
    @State private var detail: Series
    @State private var episodes: [Episode] = []
    @State private var loading = true
    @State private var play: Episode?
    @ObservedObject private var store = WatchStore.shared

    init(series: Series) { self.series = series; _detail = State(initialValue: series) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !detail.intro.isEmpty {
                    Text(detail.intro).font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65)).padding(.horizontal)
                }
                if let p = store.progress(seriesId: series.id) {
                    Button {
                        if p.episode >= 1 && p.episode <= episodes.count { play = episodes[p.episode - 1] }
                    } label: {
                        Label("继续观看 第\(p.episode)集", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.pink).padding(.horizontal)
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else { episodeGrid }
            }.padding(.vertical)
        }
        .navigationTitle(detail.title).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $play) { ep in
            PlayerView(series: detail, episodes: episodes, start: ep)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: detail.cover)) { $0.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Rectangle().fill(Color.white.opacity(0.08)) }
                .frame(width: 110, height: 146).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.title).font(.headline)
                Text("共 \(max(detail.episodeCount, episodes.count)) 集"
                     + (detail.accessibleCount > 0 ? " · 免费 \(detail.accessibleCount) 集" : ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !detail.tags.isEmpty {
                    Text(detail.tags.prefix(4).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.pink.opacity(0.9))
                }
            }
            Spacer()
        }.padding(.horizontal)
    }

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选集").font(.headline).padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 8)], spacing: 8) {
                ForEach(episodes) { ep in
                    Button { play = ep } label: {
                        Text("\(ep.index)")
                            .font(.system(size: 14, weight: store.progress(seriesId: series.id)?.episode == ep.index ? .bold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(store.progress(seriesId: series.id)?.episode == ep.index
                                        ? Color.pink.opacity(0.35) : Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).foregroundStyle(.white)
                }
            }.padding(.horizontal)
        }
    }

    private func load() async {
        loading = true
        if let (s, e) = try? await Catalog.detail(series.id) {
            if !s.title.isEmpty { detail = s }
            episodes = e
        }
        loading = false
    }
}
