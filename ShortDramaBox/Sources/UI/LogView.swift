import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 运行日志页：闪退之后，把这里的内容复制出来发给我就能定位。
/// 也可以完全不用这个页面 —— 日志同时在「文件」App 里：
/// 我的 iPhone → 短剧盒子 → 日志 → app.log / crash.log
struct LogView: View {
    @State private var text = ""
    @State private var copied = false
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: HGLog.shared.fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear { reload() }
            .confirmationDialog("清空全部日志？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    HGLog.shared.clear()
                    reload()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if HGLog.shared.hadCrashLastRun {
                Label("上次运行异常结束，崩溃线索已记进 crash.log",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button(copied ? "已复制 ✓" : "复制全部") { copyAll() }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                Button("刷新") { reload() }
                    .buttonStyle(.bordered)
                Button("清空", role: .destructive) { confirmClear = true }
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
            Text("复制后直接粘给我即可。也可以走「文件」App：我的 iPhone → 短剧盒子 → 日志。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        text = HGLog.shared.text()
    }

    private func copyAll() {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}