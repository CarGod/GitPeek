import Foundation
import Combine

// 额度统计服务。两条数据源：
//  1) 官方 5h/周：Claude Code 通过 statusLine 钩子把 rate_limits 写到 statusline-input.json，
//     我们读它拿到官方 used_percentage + resets_at（和 /usage 完全一致）。
//  2) Fable 用量：官方没有 Fable 单独窗口，故从 ~/.claude/projects 的会话记录里增量统计近 7 天 Fable work-tokens。
// 沿用 GitService 模式：后台队列跑 IO，回主线程发布；内容不变不重赋 @Published。
final class UsageService: ObservableObject {
    @Published private(set) var stats: UsageStats = .empty

    private let fm = FileManager.default
    private let work = DispatchQueue(label: "gitpeek.usage", qos: .utility)
    private var timer: Timer?

    private let supportDir: String
    private let inputFile: String
    private let scriptFile: String
    private let projectsDir: String
    private let settingsFile: String

    // Fable 增量缓存：每个 jsonl 已消费到的字节偏移 + 已解析出的 Fable 条目（只保留近 7 天）。
    private struct FableEntry { var ts: Double; var tokens: Int; var id: String }
    private struct FableFile { var offset: Int; var entries: [FableEntry] }
    private var fableCache: [String: FableFile] = [:]

    init() {
        let home = NSHomeDirectory()
        supportDir = home + "/Library/Application Support/GitPeek"
        inputFile = supportDir + "/statusline-input.json"
        scriptFile = supportDir + "/statusline.sh"
        projectsDir = home + "/.claude/projects"
        settingsFile = home + "/.claude/settings.json"
    }

    func start() {
        installHookIfNeeded()
        refresh()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        work.async { [weak self] in
            guard let self else { return }
            let (five, seven, official) = self.readOfficial()
            // Fable 周窗口和官方 7 天窗口共用同一个每周重置边界。拿到官方 resets_at 时，
            // 把用量统计对齐到「本周期起点」(resets_at − 7d)，让百分比与倒计时指向同一个窗口；
            // 官方数据还没到时退回滚动近 7 天。
            let weekStart = seven?.resetsAt.map { $0.timeIntervalSince1970 - 7 * 24 * 3600 }
            let fable = self.fableTokens(since: weekStart)
            let s = UsageStats(fiveHour: five, sevenDay: seven, fableTokens: fable, hasOfficial: official)
            DispatchQueue.main.async {
                if self.stats != s { self.stats = s }
            }
        }
    }

    // MARK: - 官方 5h / 周（读 statusLine 钩子写出的 rate_limits）

    private func readOfficial() -> (RateWindow?, RateWindow?, Bool) {
        guard let data = fm.contents(atPath: inputFile),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = obj["rate_limits"] as? [String: Any] else { return (nil, nil, false) }
        return (window(rl["five_hour"]), window(rl["seven_day"]), true)
    }

    private func window(_ any: Any?) -> RateWindow? {
        guard let w = any as? [String: Any] else { return nil }
        let p = percent(w["used_percentage"])
        let r = parseDate(w["resets_at"])
        guard p != nil || r != nil else { return nil }
        return RateWindow(percent: p ?? 0, resetsAt: r)
    }

    private func percent(_ v: Any?) -> Int? {
        let d: Double
        if let n = v as? Double { d = n }
        else if let n = v as? Int { d = Double(n) }
        else if let s = v as? String, let n = Double(s) { d = n }
        else { return nil }
        return max(0, min(100, Int(d.rounded())))
    }

    // resets_at 可能是数值（秒或毫秒）或 ISO8601 字符串，全部兼容。
    private func parseDate(_ v: Any?) -> Date? {
        if let n = v as? Double { return epoch(n) }
        if let n = v as? Int { return epoch(Double(n)) }
        if let s = v as? String {
            if let n = Double(s) { return epoch(n) }
            return Self.iso.date(from: s) ?? Self.isoPlain.date(from: s)
        }
        return nil
    }

    private func epoch(_ n: Double) -> Date {
        let ms = n > 1_000_000_000_000 ? n : n * 1000   // >1e12 视为毫秒，否则秒
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    // MARK: - Fable 近 7 天用量（增量扫描 jsonl）

    private func fableTokens(since weekStart: Double?) -> Int {
        // retention：缓存保留 & 增量扫描的下限，恒为滚动近 7 天（保证有足够历史可汇总）。
        let retention = Date().timeIntervalSince1970 - 7 * 24 * 3600
        if let projs = try? fm.contentsOfDirectory(atPath: projectsDir) {
            var live = Set<String>()
            for proj in projs {
                let dir = projectsDir + "/" + proj
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                      let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for f in files where f.hasSuffix(".jsonl") {
                    let full = dir + "/" + f
                    live.insert(full)
                    scanFableFile(full, cutoff: retention)
                }
            }
            for k in Array(fableCache.keys) where !live.contains(k) { fableCache[k] = nil }
        }
        // 汇总下限：优先「本周期起点」(与倒计时对齐)，官方数据未到时退回滚动 7 天；
        // 不早于 retention（缓存只保留到那里）。跨文件按 message.id 去重（一次回复跨多行会重复带 usage）。
        let from = max(weekStart ?? retention, retention)
        var seen = Set<String>(); var sum = 0
        for (_, file) in fableCache {
            for e in file.entries where e.ts >= from {
                if !e.id.isEmpty {
                    if seen.contains(e.id) { continue }
                    seen.insert(e.id)
                }
                sum += e.tokens
            }
        }
        return sum
    }

    private func scanFableFile(_ path: String, cutoff: Double) {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return }
        var cache = fableCache[path] ?? FableFile(offset: 0, entries: [])

        // 从未读过、且整文件在 7 天前就没动过 → 不可能有近 7 天 Fable，记为已知空、跳过。
        if cache.offset == 0 && cache.entries.isEmpty {
            if let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970, m < cutoff {
                fableCache[path] = cache
                return
            }
        }
        if size == cache.offset {                      // 无新增字节
            cache.entries.removeAll { $0.ts < cutoff }
            fableCache[path] = cache
            return
        }
        if size < cache.offset {                       // 被截断/重写 → 从头来
            cache = FableFile(offset: 0, entries: [])
        }
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(cache.offset)) } catch { return }
        let data = fh.readDataToEndOfFile()
        // 只消费到最后一个换行；残缺行留到下次（下次从 offset 续读）。
        guard !data.isEmpty, let lastNL = data.lastIndex(of: 0x0A) else {
            fableCache[path] = cache; return
        }
        let consumed = data[data.startIndex...lastNL]
        cache.offset += consumed.count
        if let text = String(data: consumed, encoding: .utf8) {
            text.enumerateLines { line, _ in
                if let e = Self.parseFableLine(line) { cache.entries.append(e) }
            }
        }
        cache.entries.removeAll { $0.ts < cutoff }     // 修剪，防止无界增长
        fableCache[path] = cache
    }

    private static func parseFableLine(_ line: String) -> FableEntry? {
        // 快速预筛：绝大多数行不含 fable，避免对每一行做 JSON 解析。
        guard line.contains("fable") else { return nil }
        guard let data = line.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (d["type"] as? String) == "assistant",
              let msg = d["message"] as? [String: Any],
              let model = msg["model"] as? String, model.lowercased().contains("fable"),
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let tokens = intOf(usage["input_tokens"]) + intOf(usage["output_tokens"])
            + intOf(usage["cache_creation_input_tokens"])
        let id = (msg["id"] as? String) ?? ""
        let ts = (d["timestamp"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }?
            .timeIntervalSince1970 ?? 0
        return FableEntry(ts: ts, tokens: tokens, id: id)
    }

    private static func intOf(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let n = v as? Double { return Int(n) }
        if let s = v as? String, let n = Int(s) { return n }
        return 0
    }

    // MARK: - 安装 statusLine 钩子（把官方 rate_limits 落盘给我们读）

    private func installHookIfNeeded() {
        try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        # GitPeek statusLine bridge —— 捕获 Claude Code 的 rate_limits（官方 5h/周 用量）。
        # Claude Code 把 statusLine 的 JSON 经 stdin 传入（含来自 /api/oauth/usage 的 rate_limits）。
        # 这里只原子写盘给 GitPeek 读，不打印任何东西（隐形，不影响你的终端状态栏）。
        dir="$HOME/Library/Application Support/GitPeek"
        mkdir -p "$dir" 2>/dev/null
        tmp="$dir/statusline-input.json.tmp.$$"
        cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/statusline-input.json" 2>/dev/null
        exit 0
        """
        if (try? String(contentsOfFile: scriptFile, encoding: .utf8)) != script {
            try? script.write(toFile: scriptFile, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile)
        wireStatusLine()
    }

    // 安装/修正 statusLine。别人的 statusLine 不覆盖（避免破坏用户配置）；我们自己的若形态不对则自愈。
    private func wireStatusLine() {
        guard let data = fm.contents(atPath: settingsFile),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        // Claude Code 是把 command 字符串交给 shell 执行的。脚本路径含空格（"Application Support"），
        // 不加引号会被拆词 → 找不到脚本（exit 127），钩子永不触发，5h/周 永远没数据。故整体单引号包裹。
        let quoted = "'\(scriptFile)'"

        if let sl = json["statusLine"] as? [String: Any] {
            let cmd = (sl["command"] as? String) ?? ""
            let isOurs = cmd.contains(scriptFile)          // 指向本脚本 = 我们装的（不管有没有引号）
            if !isOurs || cmd == quoted { return }         // 用户自有，或已是正确形态 → 不动
            var fixed = sl                                 // 是我们的但没加引号 → 修正
            fixed["command"] = quoted
            json["statusLine"] = fixed
        } else {
            let bak = settingsFile + ".gitpeek-bak"
            if !fm.fileExists(atPath: bak) { try? data.write(to: URL(fileURLWithPath: bak)) }
            json["statusLine"] = ["type": "command", "command": quoted, "padding": 0]
        }

        if let out = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: URL(fileURLWithPath: settingsFile))
        }
    }
}
