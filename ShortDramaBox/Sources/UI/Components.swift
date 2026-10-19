import SwiftUI

/// 观看进度 / 历史（本地持久化）
final class WatchStore: ObservableObject {
    static let shared = WatchStore()
    struct Item: Codable, Identifiable {
        var id: String { seriesId }
        let seriesId: String
        var title: String
        var cover: String
        var episode: Int
        var seconds: Double
        var updated: Date
    }
    @Published private(set) var items: [Item] = []
    private let key = "watch_history"

    init() { load() }
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([Item].self, from: d) else { return }
        items = v.sorted { $0.updated > $1.updated }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
    func progress(seriesId: String) -> Item? { items.first { $0.seriesId == seriesId } }
    func record(seriesId: String, title: String, cover: String, episode: Int, seconds: Double) {
        var list = items.filter { $0.seriesId != seriesId }
        list.insert(Item(seriesId: seriesId, title: title, cover: cover,
                         episode: episode, seconds: seconds, updated: Date()), at: 0)
        items = Array(list.prefix(100)); save()
    }
    func remove(seriesId: String) {
        items.removeAll { $0.seriesId == seriesId }; save()
    }
    func clear() { items = []; save() }
}

struct PosterCard: View {
    let series: Series
    var width: CGFloat = 120
    var progressText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: series.cover)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)))
                    }
                }
                .frame(width: width, height: width * 4 / 3)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let t = progressText ?? (series.rightText.isEmpty ? nil : series.rightText) {
                    Text(t).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
            }
            Text(series.title).font(.system(size: 12)).lineLimit(2)
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: width, alignment: .leading)
        }
    }
}
