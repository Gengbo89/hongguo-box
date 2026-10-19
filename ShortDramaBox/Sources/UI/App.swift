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
    var body: some View {
        TabView {
            HomeView().tabItem { Label("首页", systemImage: "house.fill") }
            BrowseView().tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
            SearchView().tabItem { Label("搜索", systemImage: "magnifyingglass") }
            HistoryView().tabItem { Label("记录", systemImage: "clock.fill") }
        }
        .tint(.pink)
    }
}
