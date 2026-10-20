import SwiftUI

/// iOS 16 兼容版 ContentUnavailableView（系统版要求 iOS 17+）
/// 保持与系统版一致的调用形态，便于日后直接换回。
struct CompatUnavailable: View {
    let title: String
    let systemImage: String
    let desc: String?

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.desc = nil
        // Text 没有公开的取值方式，故改为 String 重载
    }

    init(_ title: String, systemImage: String, desc: String) {
        self.title = title
        self.systemImage = systemImage
        self.desc = desc
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 19, weight: .semibold))
            if let d = desc {
                Text(d).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// 搜索无结果占位
struct CompatSearchEmpty: View {
    let text: String
    var body: some View {
        CompatUnavailable("没有找到“\(text)”", systemImage: "magnifyingglass",
                          desc: "换个片名试试")
    }
}
