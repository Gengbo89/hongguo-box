// 命令行入口：给 vid/剧集产出数据与可播放 mp4。复用 App 的已验证 Core 代码。
// 编译: swiftc -parse-as-library -O HG2.swift Sources/Core/*.swift -o hg2
import Foundation

func jstr(_ s: String) -> String {
    var o = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        case "\r": o += "\\r"
        case "\t": o += "\\t"
        default:
            if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
        }
    }
    return "\"\(o)\""
}

func emit(_ s: String) { print(s) }

@main
struct HG2 {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 2 else {
            FileHandle.standardError.write("usage: home | category <slug> | detail <sid> | tracks <vid> | prepare <vid> <def> <out>\n".data(using: .utf8)!)
            exit(2)
        }
        switch a[1] {

        case "home":
            do {
                let secs = try await Catalog.home()
                var out = "["
                for (i, s) in secs.enumerated() {
                    if i > 0 { out += "," }
                    out += "{\"name\":\(jstr(s.name)),\"items\":["
                    out += s.items.map { ser in
                        "{\"id\":\(jstr(ser.id)),\"title\":\(jstr(ser.title)),\"cover\":\(jstr(ser.cover)),\"right\":\(jstr(ser.rightText)),\"eps\":\(ser.episodeCount)}"
                    }.joined(separator: ",")
                    out += "]}"
                }
                emit(out + "]")
            } catch { FileHandle.standardError.write("err \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }

        case "category":
            guard a.count >= 3 else { exit(2) }
            do {
                let list = try await Catalog.category(a[2])
                emit("[" + list.map { ser in
                    "{\"id\":\(jstr(ser.id)),\"title\":\(jstr(ser.title)),\"cover\":\(jstr(ser.cover)),\"right\":\(jstr(ser.rightText)),\"eps\":\(ser.episodeCount)}"
                }.joined(separator: ",") + "]")
            } catch { FileHandle.standardError.write("err \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }

        case "detail":
            guard a.count >= 3 else { exit(2) }
            do {
                let (s, eps) = try await Catalog.detail(a[2])
                emit("{\"id\":\(jstr(s.id)),\"title\":\(jstr(s.title)),\"cover\":\(jstr(s.cover)),\"intro\":\(jstr(s.intro)),\"episodes\":\(s.episodeCount),\"access\":\(s.accessibleCount),\"tags\":[" + s.tags.map(jstr).joined(separator: ",") + "],\"vids\":[" + eps.map { "{\"i\":\($0.index),\"vid\":\(jstr($0.vid))}" }.joined(separator: ",") + "]}")
            } catch { FileHandle.standardError.write("err \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }

        case "tracks":
            guard a.count >= 3 else { exit(2) }
            let ts = await PlayerAPI.tracks(for: a[2])
            emit("[" + ts.map { t in
                "{\"def\":\(jstr(t.definition)),\"w\":\(t.width),\"h\":\(t.height),\"codec\":\(jstr(t.codec)),\"url\":\(jstr(t.url)),\"plain\":\(t.spadeA.isEmpty)}"
            }.joined(separator: ",") + "]")

        case "prepare":
            guard a.count >= 5 else { exit(2) }
            let vid = a[2], def = a[3], out = a[4]
            let ts = await PlayerAPI.tracks(for: vid)
            guard let t = ts.first(where: { $0.definition == def }) ?? ts.last else {
                FileHandle.standardError.write("no track\n".data(using: .utf8)!); exit(1)
            }
            do {
                let url = try await MediaStore.prepare(vid: vid, track: t) { _ in }
                try? FileManager.default.removeItem(atPath: out)
                try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: out))
                emit("ok \(t.definition) \(t.width)x\(t.height)")
            } catch { FileHandle.standardError.write("err \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }

        default: exit(2)
        }
    }
}
