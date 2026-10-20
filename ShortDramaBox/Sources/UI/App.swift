import SwiftUI

@main
struct DuanjuApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        // 记录当前选中的 Tab：推荐页要在切走时停掉后台预取，
        // 否则人在详情页时它还在下两三路 1080p，把带宽占满。
        TabView(selection: $tab) {
            FeedView(active: tab == 0).tag(0)
                .tabItem { Label("推荐", systemImage: "play.rectangle.fill") }
            HomeView().tag(1).tabItem { Label("首页", systemImage: "house.fill") }
            BrowseView().tag(2).tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
            SearchView().tag(3).tabItem { Label("搜索", systemImage: "magnifyingglass") }
            HistoryView().tag(4).tabItem { Label("记录", systemImage: "clock.fill") }
        }
        .tint(.pink)
    }
}
