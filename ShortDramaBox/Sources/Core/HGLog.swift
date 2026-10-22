import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// 落地日志 + 崩溃线索（HG = 红果）。
///
/// 目标只有一个：**闪退之后能知道崩在哪一步**。为此做了四件事：
///   1. 每条日志**同步写盘** —— 进程被系统直接杀掉时，文件里最后一行就是现场；
///   2. 每行都带当前内存占用（phys_footprint）—— 被 Jetsam 杀掉时能看出涨到多少；
///   3. 注册 NSException 与常见信号处理，崩溃瞬间再补一条线索；
///   4. 文件放在 Documents/日志/，用「文件」App 就能拿走，不需要 Mac、不需要 Xcode。
final class HGLog: @unchecked Sendable {
    static let shared = HGLog()

    private static let seenKey = "hglog.crash.seen"

    private let lock = NSLock()
    private let dir: URL
    private let maxBytes: Int
    private var fh: FileHandle?
    private var size = 0
    private var crashFD: Int32 = -1
    private var ticker: DispatchSourceTimer?
    private var tick = 0
    private var lastMem = -1
    private var started = false

    /// 上次运行是不是异常结束（下次启动时看 crash.log 有没有新内容）
    private(set) var hadCrashLastRun = false

    let fileURL: URL
    let crashURL: URL

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(directory: URL? = nil, maxBytes: Int = 1_500_000) {
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base
        self.maxBytes = maxBytes
        fileURL = base.appendingPathComponent("app.log")
        crashURL = base.appendingPathComponent("crash.log")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - 启动

    /// App 一启动就调用：装机信息 + 崩溃处理 + 系统事件 + 内存心跳
    static func start() {
        let s = shared
        s.lock.lock()
        if s.started { s.lock.unlock(); return }
        s.started = true
        s.lock.unlock()

        s.prepareCrashFile()
        s.bootLine()
        s.installExceptionHandler()
        s.installSignals()
        s.observeSystem()
        s.startTicker()
    }

    private func prepareCrashFile() {
        let seen = UserDefaults.standard.integer(forKey: Self.seenKey)
        let current = fileSize(crashURL)
        hadCrashLastRun = current > seen
        UserDefaults.standard.set(current, forKey: Self.seenKey)

        crashFD = open(crashURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        // 日志要在锁屏、后台也能写进去，别被数据保护挡住
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: dir.path)
        #endif
    }

    private func bootLine() {
        var d = ""
        #if canImport(UIKit)
        let dev = UIDevice.current
        d += "设备=\(dev.model) 系统=\(dev.systemName) \(dev.systemVersion) "
        let b = UIScreen.main.bounds
        d += "屏幕=\(Int(b.width))x\(Int(b.height)) "
        #endif
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let n = info?["CFBundleVersion"] as? String ?? "?"
        d += "版本=\(v)(\(n))"
        writeLocked("I", "启动", d.isEmpty ? "app 启动" : d)
        if hadCrashLastRun {
            writeLocked("W", "启动", "上次运行异常结束，crash.log 里有线索")
        }
    }

    private func startTicker() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let m = HGLog.memoryMB()
            self.tick += 1
            // 只在明显变化时记，免得日志被内存行刷满
            if self.lastMem < 0 || abs(m - self.lastMem) >= 10 || self.tick % 5 == 0 {
                self.lastMem = m
                self.emit("M", "内存", "当前 \(m)MB")
            }
        }
        t.resume()
        ticker = t
    }

    // MARK: - 写

    static func i(_ tag: String, _ msg: String) { shared.emit("I", tag, msg) }
    static func w(_ tag: String, _ msg: String) { shared.emit("W", tag, msg) }
    static func e(_ tag: String, _ msg: String) { shared.emit("E", tag, msg) }

    func emit(_ level: String, _ tag: String, _ msg: String) {
        lock.lock()
        defer { lock.unlock() }
        writeLocked(level, tag, msg)
    }

    private func writeLocked(_ level: String, _ tag: String, _ msg: String) {
        let mem = HGLog.memoryMB()
        let line = "\(HGLog.stamp.string(from: Date())) [\(level)] \(tag): \(msg)  (内存 \(mem)MB)\n"
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded(data.count)
        openIfNeeded()
        try? fh?.write(contentsOf: data)
        size += data.count
    }

    /// 需要留痕的异常（未必当场崩，例如被捕获的 NSException）
    func record(kind: String, detail: String) {
        let text = "\n===== \(Date()) \(kind) =====\n\(detail)\n"
        lock.lock()
        defer { lock.unlock() }
        appendCrashLocked(text)
        writeLocked("X", "崩溃", detail.replacingOccurrences(of: "\n", with: " ⏎ "))
    }

    private func appendCrashLocked(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if fileSize(crashURL) > 400_000 {
            try? FileManager.default.removeItem(at: crashURL)
        }
        if let h = try? FileHandle(forWritingTo: crashURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: crashURL)
        }
    }

    private func openIfNeeded() {
        guard fh == nil else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            size = 0
        }
        fh = try? FileHandle(forWritingTo: fileURL)
        if let h = fh {
            let end = (try? h.seekToEnd()) ?? 0
            if end > 0 { size = Int(end) }
        }
    }

    private func rotateIfNeeded(_ incoming: Int) {
        guard size + incoming > maxBytes else { return }
        try? fh?.close()
        fh = nil
        let old = dir.appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
        size = 0
    }

    private func fileSize(_ u: URL) -> Int {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        return (a?[.size] as? Int) ?? 0
    }

    // MARK: - 读 / 清

    /// 给「日志」页用：崩溃线索在前，运行日志在后（都是尾部）
    func text(maxBytes: Int = 400_000) -> String {
        lock.lock()
        defer { lock.unlock() }
        var out = ""
        if let c = try? String(contentsOf: crashURL, encoding: .utf8), !c.isEmpty {
            out += "===== crash.log（崩溃线索，新的在后）=====\n" + tail(c, maxBytes / 2) + "\n\n"
        }
        if let a = try? String(contentsOf: fileURL, encoding: .utf8), !a.isEmpty {
            out += "===== app.log（运行日志尾部）=====\n" + tail(a, maxBytes)
        }
        if out.isEmpty { out = "（还没有日志）" }
        return out
    }

    private func tail(_ s: String, _ n: Int) -> String {
        guard s.utf8.count > n else { return s }
        return "…（更早的内容已省略）\n" + String(s.suffix(n))
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? fh?.close()
        fh = nil
        size = 0
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("app.log.1"))
        try? FileManager.default.removeItem(at: crashURL)
        UserDefaults.standard.set(0, forKey: Self.seenKey)
        hadCrashLastRun = false
    }

    /// 日志目录（提示用户去「文件」App 哪里找）
    var dirPath: String { dir.path }

    // MARK: - 内存

    /// phys_footprint：Jetsam 就是盯这个值杀进程的，所以记它最有意义
    static func memoryMB() -> Int {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), q, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(vm.phys_footprint / 1024 / 1024)
    }

    // MARK: - 崩溃捕获

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { ex in
            let detail = "name=\(ex.name.rawValue)\nreason=\(ex.reason ?? "-")\n"
                + Thread.callStackSymbols.joined(separator: "\n")
            HGLog.shared.record(kind: "未捕获异常", detail: detail)
        }
    }

    private func installSignals() {
        let sigs: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for s in sigs {
            signal(s) { sig in
                HGLog.writeSignal(sig)
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }

    /// 信号处理里只能做异步信号安全的事：写预先打开的 fd，除此之外什么都不碰。
    /// 真正的现场靠 crash.log 上面那几行已经落盘的日志。
    private static func writeSignal(_ sig: Int32) {
        let fd = shared.crashFD
        guard fd >= 0 else { return }
        let name: String
        switch sig {
        case SIGSEGV: name = "SIGSEGV 内存越界/野指针"
        case SIGABRT: name = "SIGABRT 主动终止（断言 / fatalError）"
        case SIGBUS:  name = "SIGBUS 总线错误（坏内存访问）"
        case SIGILL:  name = "SIGILL 非法指令（Swift 运行时陷阱）"
        case SIGFPE:  name = "SIGFPE 算术异常"
        case SIGTRAP: name = "SIGTRAP 陷阱（数组越界 / 强制解包失败）"
        default:      name = "信号 \(sig)"
        }
        let line = "\n*** 进程崩溃：\(name) ***\n"
        _ = line.withCString { p in Darwin.write(fd, p, strlen(p)) }
    }

    private func observeSystem() {
        #if canImport(UIKit)
        let c = NotificationCenter.default
        c.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                      object: nil, queue: .main) { _ in
            HGLog.w("内存", "收到系统内存警告")
        }
        c.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                      object: nil, queue: .main) { _ in
            HGLog.i("生命周期", "进入后台")
        }
        c.addObserver(forName: UIApplication.willEnterForegroundNotification,
                      object: nil, queue: .main) { _ in
            HGLog.i("生命周期", "回到前台")
        }
        c.addObserver(forName: UIApplication.willTerminateNotification,
                      object: nil, queue: .main) { _ in
            HGLog.i("生命周期", "即将终止")
        }
        c.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                      object: nil, queue: .main) { n in
            let e = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "-"
            HGLog.e("播放", "播放中断：\(e)")
        }
        #endif
    }
}