#if canImport(UIKit)
import UIKit
#endif
import Foundation
import SwiftUI

/// 版本标识与更新检查
enum AppVersion {
    /// 展示用版本号，如 "1.0.10"
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    /// 构建号，对应 CI 的第几次构建
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
    /// "1.0.10（构建 10）"
    static var display: String { "\(short)（构建 \(build)）" }

    /// 构建号转 Int，用于比较新旧
    static var buildNumber: Int { Int(build) ?? 0 }
}

/// 更新检查结果
enum UpdateState: Equatable {
    case idle
    case checking
    case latest                       // 已是最新
    case newer(String)                // 有新版本（标签，如 build-16）
    case failed(String)
}

/// 从 GitHub Release 读取最新构建号并比较
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var state: UpdateState = .idle

    static let repo = "Gengbo89/hongguo-box"
    static var releasesPage: String { "https://github.com/\(repo)/releases" }

    func check() async {
        state = .checking
        // 走 releases 的 atom feed：无需 token、不受 API 限流影响
        guard let u = URL(string: "https://github.com/\(Self.repo)/releases.atom") else {
            state = .failed("地址无效"); return
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("ShortDramaBox/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let xml = String(data: data, encoding: .utf8) ?? ""
            guard let tag = Self.latestTag(in: xml) else {
                state = .failed("没能解析版本信息"); return
            }
            let n = Int(tag.replacingOccurrences(of: "build-", with: "")) ?? 0
            if n > AppVersion.buildNumber {
                state = .newer(tag)
            } else {
                state = .latest
            }
        } catch {
            state = .failed("网络错误：\(error.localizedDescription)")
        }
    }

    /// 从 atom feed 里取第一个 <id>…/releases/tag/build-N</id>
    static func latestTag(in xml: String) -> String? {
        // 优先看 <entry> 内的 tag 链接
        let patterns = [
            #"/releases/tag/(build-[0-9]+)"#,
            #"<title>([^<]*build-[0-9]+[^<]*)</title>"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: xml) {
                let s = String(xml[r])
                if let re2 = try? NSRegularExpression(pattern: #"build-[0-9]+"#),
                   let m2 = re2.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let r2 = Range(m2.range, in: s) {
                    return String(s[r2])
                }
            }
        }
        return nil
    }
}

/// 「关于」页：显示版本 + 检查更新
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var checker = UpdateChecker()

    var body: some View {
        NavigationStack {
            List {
                Section("版本") {
                    LabeledContent("当前版本", value: AppVersion.display)
                    LabeledContent("构建号", value: AppVersion.build)
                    LabeledContent("应用标识", value: "com.duanju.box")
                }

                Section("更新") {
                    Button {
                        Task { await checker.check() }
                    } label: {
                        HStack {
                            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if case .checking = checker.state { ProgressView() }
                        }
                    }
                    .disabled(checker.state == .checking)

                    switch checker.state {
                    case .latest:
                        Label("已是最新版本", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.footnote)
                    case .newer(let tag):
                        VStack(alignment: .leading, spacing: 6) {
                            Label("有新版本 \(tag)", systemImage: "sparkles")
                                .foregroundStyle(.pink).font(.footnote)
                            Text("手机上装不了，需要在电脑上用 Sideloadly 覆盖安装。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    case .failed(let msg):
                        Text(msg).font(.footnote).foregroundStyle(.orange)
                    default:
                        EmptyView()
                    }
                }

                Section("怎么更新") {
                    Text("1. 在电脑上打开下面这个发布页，下载最新的 ShortDramaBox-unsigned.ipa")
                        .font(.footnote)
                    Text("2. 拖进 Sideloadly，填 Apple ID，点 Start")
                        .font(.footnote)
                    Text("3. 不要先删手机上的旧 App，直接覆盖装，观看记录和缓存都会保留")
                        .font(.footnote)
                    Text(UpdateChecker.releasesPage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("免费 Apple ID 签的 App 每 7 天过期，重跑一次 Sideloadly 续期即可。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}