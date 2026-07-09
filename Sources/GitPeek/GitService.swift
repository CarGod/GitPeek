import SwiftUI
import Combine

// 负责：取当前 iTerm2 目录 → 解析 git 仓库 → 跑 git → 发布快照。
// 所有阻塞调用在后台队列，@Published 更新回主线程。
final class GitService: ObservableObject {
    @Published var state = RepoState()

    // 每完成一次刷新周期就调用一次（无论 state 是否变化）——
    // 用于让已打开的 diff 面板在「文件内容变了但 porcelain 状态没变」时也能实时更新
    var didRefresh: (() -> Void)?

    private let work = DispatchQueue(label: "gitpeek.git", qos: .userInitiated)
    private var watcher: RepoWatcher?
    private var watchedRoot: String?
    private var refreshing = false
    private var pendingRefresh = false
    private var lastFinishedAt: TimeInterval = 0
    private let minInterval: TimeInterval = 0.4   // 两次 git 之间的最小间隔（限流）

    // 请求一次刷新（合并并发请求 + 最小间隔限流）
    func refresh() {
        if refreshing { pendingRefresh = true; return }
        let wait = minInterval - (Date().timeIntervalSince1970 - lastFinishedAt)
        if wait > 0 {
            // 距上次太近：安排一次尾随刷新，避免忙仓库把 git 打满
            if pendingRefresh { return }
            pendingRefresh = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.pendingRefresh = false
                self?.refresh()
            }
            return
        }
        startRefresh()
    }

    private func startRefresh() {
        refreshing = true
        let prev = state
        work.async { [weak self] in
            let result = GitService.buildState(previous: prev)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastFinishedAt = Date().timeIntervalSince1970
                // result == nil 表示瞬时读取失败 → 保持现状（不闪空、不重置滚动）
                if let ns = result {
                    if ns != self.state {
                        Log.write("state REASSIGN commits=\(ns.commits.count) changes=\(ns.changes.count)")
                        self.state = ns
                    }
                    self.syncWatcher(root: ns.root)
                }
                self.refreshing = false
                self.didRefresh?()
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refresh()
                }
            }
        }
    }

    // 根据仓库根启停 FSEvents 监听
    private func syncWatcher(root: String?) {
        if root == watchedRoot { return }
        watcher = nil
        watchedRoot = root
        guard let root else { return }
        watcher = RepoWatcher(path: root) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - 组装快照（后台线程）

    // 返回 nil = 本次读取不可信（目录取不到 / index.lock 抢占等瞬时失败）→ 调用方保持现状
    private static func buildState(previous: RepoState) -> RepoState? {
        guard let cwd = ITerm.currentSessionPath() else {
            return nil   // 取不到目录 → 保持现状
        }
        guard let root = Shell.git(["rev-parse", "--show-toplevel"], root: cwd), !root.isEmpty else {
            // rev-parse 失败：若仍在原仓库内，判为瞬时失败，保持现状；否则确实不是仓库
            if let prevRoot = previous.root, cwd == prevRoot || cwd.hasPrefix(prevRoot + "/") {
                return nil
            }
            return RepoState()
        }
        var s = RepoState()
        s.root = root

        // status 成功必然包含分支头；返回 nil 视为瞬时失败 → 保持现状（不闪空）
        guard let status = Shell.git(["status", "--porcelain=v2", "--branch"], root: root) else {
            return nil
        }
        parseStatus(status, into: &s)

        // 未推送提交集合（上游..HEAD）
        var unpushed = Set<String>()
        if !s.upstream.isEmpty,
           let rev = Shell.git(["rev-list", "\(s.upstream)..HEAD"], root: root) {
            for h in rev.split(separator: "\n") { unpushed.insert(String(h)) }
        }

        if let log = Shell.git(
            ["log", "-n", "80", "--pretty=format:%H%x1f%h%x1f%D%x1f%s"], root: root) {
            s.commits = parseLog(log, unpushed: unpushed)
        }
        return s
    }

    private static func parseStatus(_ text: String, into s: inout RepoState) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("# branch.head ") {
                s.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                s.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // 形如 "+13 -0"
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for p in parts {
                    if p.hasPrefix("+") { s.ahead = Int(p.dropFirst()) ?? 0 }
                    if p.hasPrefix("-") { s.behind = Int(p.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count >= 9 else { continue }
                let xy = String(fields[1])
                let x = xy.first ?? "."
                let y = xy.count > 1 ? xy[xy.index(after: xy.startIndex)] : "."
                var path = String(fields[8])
                var oldPath: String? = nil
                if line.hasPrefix("2 ") {
                    // rename/copy：第 9 段是 "<Xscore>"，第 10 段是 "<新路径>\t<旧路径>"
                    let f2 = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                    if f2.count >= 10 {
                        let parts = String(f2[9]).components(separatedBy: "\t")
                        path = parts.first ?? String(f2[9])
                        if parts.count >= 2 { oldPath = parts[1] }
                    }
                }
                let staged = x != "."
                let code = (y != ".") ? y : x
                s.changes.append(ChangeEntry(path: path, letter: letter(for: code), staged: staged, oldPath: oldPath))
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let p = fields.last { s.changes.append(ChangeEntry(path: String(p), letter: "!", staged: false)) }
            } else if line.hasPrefix("? ") {
                s.changes.append(ChangeEntry(path: String(line.dropFirst(2)), letter: "U", staged: false))
            }
            // "! " ignored 跳过
        }
        // 全序排序：主按路径，同路径再按 staged / 状态字母兜底，
        // 保证同一 git 输出的顺序完全确定（不依赖排序算法的稳定性）→ RepoState 可判等
        s.changes.sort {
            let a = $0.path.lowercased(), b = $1.path.lowercased()
            if a != b { return a < b }
            if $0.staged != $1.staged { return $0.staged && !$1.staged }
            return $0.letter < $1.letter
        }
    }

    private static func letter(for code: Character) -> String {
        switch code {
        case "M": return "M"
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "C": return "C"
        case "U": return "!"
        default: return "M"
        }
    }

    private static func parseLog(_ text: String, unpushed: Set<String>) -> [CommitEntry] {
        let sep = Character("\u{1f}")
        var out: [CommitEntry] = []
        var first = true
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let cols = raw.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4 else { continue }
            let full = cols[0]
            let refs = parseRefs(cols[2])
            let pushed = unpushed.isEmpty ? true : !unpushed.contains(full)
            out.append(CommitEntry(hash: cols[1], subject: cols[3], refs: refs,
                                   pushed: pushed, isHead: first))
            first = false
        }
        return out
    }

    private static func parseRefs(_ s: String) -> [String] {
        // %D 形如 "HEAD -> main, origin/main, tag: v1.0"
        guard !s.isEmpty else { return [] }
        return s.split(separator: ",").map {
            var r = $0.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("HEAD -> ") { r = String(r.dropFirst("HEAD -> ".count)) }
            return r
        }.filter { !$0.isEmpty }
    }
}
