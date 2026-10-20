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
    case newer(String, String)        // 有新版本（标签, 下载页）
    case failed(String)
}

/// 从 GitHub Release 读取最新构建号并比较
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var state: UpdateState = .idle

    static let repo = "Gengbo89/hongguo-box"
    static var releasesPage: String { "https://github.com/\(repo)/releases" }

    /// SideStore / AltStore 侧载源地址。
    /// 在 SideStore 里加一次这个源，之后有新版本 SideStore 会自己提示，手机上点一下就装好。
    /// 走 releases/latest/download：github.com 国内实测可达，
    /// 而 raw.githubusercontent.com / jsDelivr 实测都连不上，不能用。
    static let sourceURL = "https://github.com/\(repo)/releases/latest/download/apps.json"
    static let sidestoreSite = "https://sidestore.io"

    /// 最新 release 的下载直链（未签名 IPA）
    static func ipaURL(tag: String) -> String {
        "https://github.com/\(repo)/releases/download/\(tag)/ShortDramaBox-unsigned.ipa"
    }

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
                state = .newer(tag, Self.ipaURL(tag: tag))
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
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("版本") {
                    LabeledContent("当前版本", value: AppVersion.display)
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
                    case .newer(let tag, let url):
                        VStack(alignment: .leading, spacing: 8) {
                            Label("有新版本 \(tag)", systemImage: "sparkles")
                                .foregroundStyle(.pink).font(.footnote)
                            if let u = URL(string: url) {
                                Link("下载新版本 IPA", destination: u).font(.footnote)
                            }
                            if let u = URL(string: UpdateChecker.releasesPage) {
                                Link("打开发布页", destination: u).font(.footnote)
                            }
                        }
                    case .failed(let msg):
                        Text(msg).font(.footnote).foregroundStyle(.orange)
                    default:
                        EmptyView()
                    }
                }

                Section("如何更新") {
                    Text("iOS 不允许 App 自己安装更新（App 改不了自己的安装包），所以「检查更新」只能告诉你有没有新版、把安装包地址给你。真正装上必须由外部安装器来做。")
                        .font(.footnote).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("方式一：SideStore（不用电脑，推荐）", systemImage: "1.circle.fill")
                            .font(.footnote).foregroundStyle(.pink)
                        Text("在 SideStore 里加一次下面的源，以后它自己就会提示有新版本，手机上点一下「更新」就装好了，观看记录保留。")
                            .font(.footnote)
                        Text(UpdateChecker.sourceURL)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = UpdateChecker.sourceURL
                            #endif
                            copied = true
                        } label: {
                            Label(copied ? "已拷贝" : "拷贝源地址",
                                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.footnote)
                        }
                        if let u = URL(string: UpdateChecker.sidestoreSite) {
                            Link("SideStore 官网（初次安装需要一台电脑）", destination: u)
                                .font(.footnote)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("方式二：Sideloadly（电脑覆盖安装）", systemImage: "2.circle.fill")
                            .font(.footnote)
                        Text("点上面的「检查更新」，下载新 IPA，用 Sideloadly 装到手机上。不要先删掉旧 App，直接覆盖，记录和缓存都在。")
                            .font(.footnote)
                    }

                    Text("免费 Apple ID 签的 App 每 7 天过期，重装或让 SideStore 后台刷新即可。")
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