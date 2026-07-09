import Foundation

enum Log {
    static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GitPeek.log")

    private static let q = DispatchQueue(label: "gitpeek.log")

    static func write(_ msg: String) {
        q.async {
            let line = "\(stamp()) \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // 只在内容变化时记，避免刷屏
    private static var last: [String: String] = [:]
    static func once(_ key: String, _ msg: String) {
        q.async {
            if last[key] == msg { return }
            last[key] = msg
            let line = "\(stamp()) \(msg)\n"
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                } else { try? data.write(to: url) }
            }
        }
    }

    private static func stamp() -> String {
        let t = Date().timeIntervalSince1970
        return String(format: "%.3f", t.truncatingRemainder(dividingBy: 100000))
    }
}
