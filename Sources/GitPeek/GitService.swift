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
                        Log.write("state REASSIGN commits=\(ns.commits.count) changes=\(ns.changes.count) repos=\(ns.availableRepos.count) parent=\((ns.reposParent as NSString?)?.lastPathComponent ?? "-")")
                        self.state = ns
                    }
                    // 单仓库监听仓库根；多仓库监听父目录（新仓库/改动即时触发，不只靠 1s 轮询）
                    self.syncWatcher(root: ns.root ?? ns.reposParent)
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
        // 已在多仓库模式、cwd 没变、且 cwd 自身没新出现 .git → 跳过必失败的 rev-parse，直接重扫
        if previous.reposParent == cwd, !previous.availableRepos.isEmpty,
           !FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(".git")) {
            guard let children = childRepos(of: cwd) else { return nil }
            guard !children.isEmpty else { return RepoState() }
            var s = RepoState(); s.availableRepos = children; s.reposParent = cwd
            return s
        }
        // A 本身在某仓库里 → 单仓库模式（父仓库优先）
        if let root = Shell.git(["rev-parse", "--show-toplevel"], root: cwd), !root.isEmpty {
            return buildRepo(root: root)
        }
        // rev-parse 失败：单仓库模式下仍在原仓库内 → 判为瞬时失败，保持现状
        if let prevRoot = previous.root, previous.availableRepos.isEmpty,
           cwd == prevRoot || cwd.hasPrefix(prevRoot + "/") {
            return nil
        }

        // 不是仓库 → 扫 depth-1 子仓库；多仓库模式只带列表，各仓库的改动由手风琴按需加载
        guard let children = childRepos(of: cwd) else { return nil }   // 读目录失败 → 保持现状
        guard !children.isEmpty else { return RepoState() }            // 读到但无子仓库 → 空状态
        var s = RepoState()
        s.availableRepos = children
        s.reposParent = cwd
        return s                                                       // root 保持 nil
    }

    // 只取某仓库的改动文件列表（手风琴展开时用）
    static func changeEntries(root: String) -> [ChangeEntry]? {
        guard let status = Shell.git(["status", "--porcelain=v2", "--branch"], root: root) else { return nil }
        var s = RepoState()
        parseStatus(status, into: &s)
        return s.changes
    }

    // 该仓库的本地分支列表（点分支下拉时懒加载）
    static func branchList(root: String) -> [String]? {
        guard let out = Shell.git(["branch", "--format=%(refname:short)"], root: root) else { return nil }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // 切换分支（git 会安全拒绝会丢数据的切换）；成功返回 nil，失败返回错误信息
    static func checkout(root: String, branch: String) -> String? {
        let r = Shell.gitResult(["checkout", branch], root: root)
        if r.ok { return nil }
        // git 的失败信息通常多行，取第一行有内容的当提示
        let firstLine = r.err.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "切换失败" : firstLine
    }

    // 读 .git/HEAD 得到当前分支（廉价文件读，不起 git）；worktree(.git 文件)/读失败返回 ""
    private static func currentBranch(root: String) -> String {
        let gitPath = (root as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir), isDir.boolValue else { return "" }
        let headPath = (gitPath as NSString).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return "" }
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ref: refs/heads/") { return String(t.dropFirst("ref: refs/heads/".count)) }
        return t.count >= 7 ? String(t.prefix(7)) : t   // detached → 短 sha
    }

    // 子仓库「本地已提交未推送」计数。守住「列目录不为每仓起 git」的约定：
    // 先纯文件系统读本地分支 tip 与上游 tip 的 sha —— 相等(已全部推送，最常见)直接 0，不起 git；
    // 仅当两者不同才 git rev-list 精确计数，并按 (localSHA, upstreamSHA) 缓存 → commit/push 后自动失效。
    private struct AheadEntry { var local: String; var upstream: String; var ahead: Int }
    private static var aheadCache: [String: AheadEntry] = [:]

    private static func aheadCount(root: String, branch: String) -> Int {
        guard !branch.isEmpty, let upRef = upstreamRef(root: root, branch: branch),
              let local = resolveRef(root: root, ref: "refs/heads/\(branch)"),
              let up = resolveRef(root: root, ref: upRef) else { return 0 }
        if local == up { aheadCache[root] = nil; return 0 }          // 全部已推送（最常见）→ 免 git
        if let c = aheadCache[root], c.local == local, c.upstream == up { return c.ahead }
        // tip 不同：精确数一次
        let n = Shell.git(["rev-list", "--count", "\(upRef)..HEAD"], root: root)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        aheadCache[root] = AheadEntry(local: local, upstream: up, ahead: n)
        return n
    }

    // 从 .git/config 解析 branch 的上游 ref。无上游(未 push/未跟踪) → nil。
    private static func upstreamRef(root: String, branch: String) -> String? {
        let cfg = (root as NSString).appendingPathComponent(".git/config")
        guard let text = try? String(contentsOfFile: cfg, encoding: .utf8) else { return nil }
        var inSection = false, remote: String?, merge: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = (line == "[branch \"\(branch)\"]"); continue }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "remote" { remote = val } else if key == "merge" { merge = val }
        }
        guard let r = remote, let m = merge else { return nil }
        let short = m.hasPrefix("refs/heads/") ? String(m.dropFirst("refs/heads/".count)) : m
        return r == "." ? m : "refs/remotes/\(r)/\(short)"   // remote "." = 本地跟踪
    }

    // 解析一个 ref 到 sha（loose 文件优先，符号引用跟随一次；否则查 packed-refs）。取不到 → nil。
    private static func resolveRef(root: String, ref: String) -> String? {
        let git = (root as NSString).appendingPathComponent(".git")
        let loose = (git as NSString).appendingPathComponent(ref)
        if let s = try? String(contentsOfFile: loose, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("ref: ") { return resolveRef(root: root, ref: String(t.dropFirst(5))) }
            if !t.isEmpty { return t }
        }
        if let packed = try? String(contentsOfFile: (git as NSString).appendingPathComponent("packed-refs"), encoding: .utf8) {
            for raw in packed.split(separator: "\n") {
                if raw.hasPrefix("#") || raw.hasPrefix("^") { continue }
                let parts = raw.split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == ref {
                    return String(parts[0])
                }
            }
        }
        return nil
    }

    // 组装单个仓库的 status + log（单仓库和子仓库共用）
    private static func buildRepo(root: String) -> RepoState? {
        var s = RepoState()
        s.root = root
        // status 成功必然包含分支头；返回 nil 视为瞬时失败 → 保持现状（不闪空）
        guard let status = Shell.git(["status", "--porcelain=v2", "--branch"], root: root) else {
            return nil
        }
        parseStatus(status, into: &s)

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

    // 扫描 dir 的「直接子目录」里哪些是 git 仓库（只一层，不递归）。
    // 纯文件系统 stat + 读 HEAD，不为每个子目录起 git。读目录失败返回 nil（瞬时，保持现状）。
    private static func childRepos(of dir: String) -> [ChildRepo]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let sorted = names.sorted()   // 廉价确定性排序（保证同一目录 → 同一数组）
        var repos: [ChildRepo] = []
        var scanned = 0
        for name in sorted {
            scanned += 1
            if scanned > 2000 { break }          // 迭代封顶：超大目录也有界
            if name == ".git" { continue }        // 跳过父目录自身的 .git（.dotfiles 等点目录仓库仍保留）
            let child = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
            // .git 目录(常规) 或 .git 文件(worktree/submodule) 都算
            if fm.fileExists(atPath: (child as NSString).appendingPathComponent(".git")) {
                let br = currentBranch(root: child)
                repos.append(ChildRepo(path: child, branch: br, ahead: aheadCount(root: child, branch: br)))
                if repos.count >= 64 { break }    // 结果封顶
            }
        }
        return repos
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
