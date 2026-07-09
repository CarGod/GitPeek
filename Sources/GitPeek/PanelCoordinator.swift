import SwiftUI
import Combine

// 统一持有：feature A（提交展开）、feature B（diff）、多仓库手风琴（子仓库展开+改动）的 UI 状态。
// 都放这里、绝不进 RepoState —— 保住「内容不变则不重赋 state」的防滚动重置不变量。
// 沿用 GitService 模式：后台队列跑 git，回主线程发布。不要标 @MainActor。
final class PanelCoordinator: ObservableObject {
    // Feature A：提交展开
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var files: [String: [CommitFileChange]] = [:]
    @Published private(set) var loadingFiles: Set<String> = []
    // Feature B：diff 面板
    @Published private(set) var isOpen: Bool = false
    @Published private(set) var diffState: DiffState = .idle
    // 多仓库手风琴：哪些子仓库展开 + 各自的改动文件（懒加载）
    @Published private(set) var expandedRepos: Set<String> = []
    @Published private(set) var repoChanges: [String: [ChangeEntry]] = [:]
    @Published private(set) var loadingRepos: Set<String> = []
    private var reloadingRepos: Set<String> = []   // 周期重载的在途去重（不显示 loading）
    // 每个子仓库的本地分支列表（点分支下拉时懒加载缓存）
    @Published private(set) var repoBranches: [String: [String]] = [:]
    private var loadingBranches: Set<String> = []

    private unowned let git: GitService
    private let work = DispatchQueue(label: "gitpeek.coord", qos: .userInitiated)
    private var diffSeq = 0
    private var current: DiffTarget?
    private var openedRoot: String?
    private var lastReposParent: String?

    init(git: GitService) { self.git = git }

    // 每个刷新周期由 GitService.didRefresh 触发
    func onRefresh() {
        reloadDiffIfNeeded()
        refreshMultiRepo()
    }

    // MARK: - 选中高亮

    func isSelected(_ t: DiffTarget) -> Bool {
        guard isOpen, let c = current else { return false }
        // 含 staged/letter：区分同 path 的暂存删除 vs 未跟踪两行（git rm --cached）
        return c.root == t.root && c.path == t.path && c.commit == t.commit
            && c.staged == t.staged && c.letter == t.letter
    }

    // MARK: - Feature A（提交展开）

    func isExpanded(_ h: String) -> Bool { expanded.contains(h) }
    func filesFor(_ h: String) -> [CommitFileChange]? { files[h] }
    func isLoadingFiles(_ h: String) -> Bool { loadingFiles.contains(h) }

    func toggleExpand(_ h: String) {
        if expanded.contains(h) { expanded.remove(h) }
        else { expanded.insert(h); loadFilesIfNeeded(h) }
    }

    private func loadFilesIfNeeded(_ h: String) {
        guard files[h] == nil, !loadingFiles.contains(h), let root = git.state.root else { return }
        loadingFiles.insert(h)
        work.async { [weak self] in
            let out = Shell.git(["diff-tree", "--no-commit-id", "--name-status", "-r", "-M", "--root", h], root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingFiles.remove(h)
                if let out { self.files[h] = PanelCoordinator.parseNameStatus(out) }
            }
        }
    }

    static func parseNameStatus(_ text: String?) -> [CommitFileChange] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let c = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 2 else { return nil }
            let code = c[0].first.map(String.init) ?? "M"
            if (code == "R" || code == "C"), c.count >= 3 {
                return CommitFileChange(path: c[2], oldPath: c[1], letter: code)
            }
            return CommitFileChange(path: c[1], oldPath: nil, letter: code)
        }
    }

    // MARK: - 多仓库手风琴

    func isRepoExpanded(_ path: String) -> Bool { expandedRepos.contains(path) }
    func changesFor(_ path: String) -> [ChangeEntry]? { repoChanges[path] }
    func isLoadingRepo(_ path: String) -> Bool { loadingRepos.contains(path) }

    func toggleRepo(_ path: String) {
        if expandedRepos.contains(path) {
            expandedRepos.remove(path)
        } else {
            expandedRepos.insert(path)
            if repoChanges[path] == nil { loadRepoChanges(path, showLoading: true) }
        }
        // 记住该父目录的展开集合（下次回到同目录/重启后恢复）
        if let parent = git.state.reposParent {
            Settings.shared.setExpandedRepos(Array(expandedRepos), forParent: parent)
        }
    }

    private func loadRepoChanges(_ path: String, showLoading: Bool) {
        if showLoading {
            guard !loadingRepos.contains(path) else { return }
            loadingRepos.insert(path)
        } else {
            guard !reloadingRepos.contains(path) else { return }   // 在途去重：慢 git status 不会堆积
            reloadingRepos.insert(path)
        }
        work.async { [weak self] in
            let ch = GitService.changeEntries(root: path)
            DispatchQueue.main.async {
                guard let self else { return }
                if showLoading { self.loadingRepos.remove(path) } else { self.reloadingRepos.remove(path) }
                guard self.expandedRepos.contains(path) else { return }
                // 只在成功且内容变化时更新（瞬时失败保留旧值、内容不变不触发重渲染）
                if let ch, self.repoChanges[path] != ch { self.repoChanges[path] = ch }
            }
        }
    }

    // 每刷新周期：父目录变了先清手风琴；否则重载已展开仓库的改动
    private func refreshMultiRepo() {
        let parent = git.state.reposParent
        if parent != lastReposParent {
            lastReposParent = parent
            expandedRepos.removeAll(); repoChanges.removeAll()
            loadingRepos.removeAll(); reloadingRepos.removeAll()
            repoBranches.removeAll(); loadingBranches.removeAll()
            if let r = openedRoot, !rootStillValid(r) { closeDiff() }
            // 恢复该父目录记住的展开（只恢复仍存在的子仓库）
            if let parent {
                let remembered = Settings.shared.expandedRepos(forParent: parent)
                for repo in git.state.availableRepos where remembered.contains(repo.path) {
                    expandedRepos.insert(repo.path)
                    loadRepoChanges(repo.path, showLoading: true)
                }
            }
            return
        }
        let paths = Set(git.state.availableRepos.map(\.path))
        // 清理已从列表消失的仓库残留（仅在确有陈旧键时才重赋，避免每 tick churn）
        if expandedRepos.contains(where: { !paths.contains($0) }) {
            expandedRepos = expandedRepos.intersection(paths)
        }
        if repoChanges.keys.contains(where: { !paths.contains($0) }) {
            repoChanges = repoChanges.filter { paths.contains($0.key) }
        }
        if repoBranches.keys.contains(where: { !paths.contains($0) }) {
            repoBranches = repoBranches.filter { paths.contains($0.key) }
        }
        for path in expandedRepos where paths.contains(path) {
            loadRepoChanges(path, showLoading: false)
        }
    }

    // 分支列表（下拉用）：nil = 还没加载完；[] = 加载完但无分支（如空仓库）
    func branchesFor(_ path: String) -> [String]? { repoBranches[path] }

    func loadBranchesIfNeeded(_ path: String) {
        guard repoBranches[path] == nil, !loadingBranches.contains(path) else { return }
        loadingBranches.insert(path)
        work.async { [weak self] in
            let bs = GitService.branchList(root: path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingBranches.remove(path)
                if let bs { self.repoBranches[path] = bs }
            }
        }
    }

    // 切换分支：成功后重载该仓库改动，并触发 state 重建（分支名更新）；失败弹提示。
    // 不清 repoBranches：切换不改变本地分支集合，当前分支勾选由 repo.branch(读 .git/HEAD)自动跟。
    func checkoutBranch(_ path: String, _ branch: String) {
        work.async { [weak self] in
            let err = GitService.checkout(root: path, branch: branch)
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.showToast(err)
                } else {
                    self.repoChanges[path] = nil
                    if self.expandedRepos.contains(path) { self.loadRepoChanges(path, showLoading: true) }
                    if self.openedRoot == path { self.lastBuildSignature = nil }   // 让打开的 diff 重建
                }
                self.git.refresh()
            }
        }
    }

    // MARK: - 提示条（切换分支失败等）

    @Published private(set) var toast: String?
    private var toastToken = 0

    private func showToast(_ msg: String) {
        toast = msg
        toastToken += 1
        let t = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.toastToken == t else { return }
            self.toast = nil
        }
    }

    // diff 指向的仓库是否仍有效（单仓库=当前 root；多仓库=在列表里）
    private func rootStillValid(_ root: String) -> Bool {
        root == git.state.root || git.state.availableRepos.contains(where: { $0.path == root })
    }

    // MARK: - Feature B（diff，主线程调用）

    private var lastBuildSignature: String?

    func openDiff(_ t: DiffTarget) {
        current = t
        openedRoot = t.root
        if !isOpen { isOpen = true }
        diffState = .loading(t)
        lastBuildSignature = t.commit == nil ? workingTreeSignature(t) : nil
        build(t)
    }

    func toggleDiff(_ t: DiffTarget) {
        if isOpen, sameTarget(current, t) { closeDiff() } else { openDiff(t) }
    }

    func closeDiff() {
        guard isOpen else { return }
        isOpen = false
        diffState = .idle
        current = nil
        openedRoot = nil
        lastBuildSignature = nil
        diffSeq += 1
    }

    func forceReloadDiff() {
        guard isOpen, let t = current else { return }
        if let r = openedRoot, !rootStillValid(r) { closeDiff(); return }
        lastBuildSignature = t.commit == nil ? workingTreeSignature(t) : nil
        build(t)
    }

    func reloadDiffIfNeeded() {
        guard isOpen, let t = current else { return }
        if let r = openedRoot, !rootStillValid(r) { closeDiff(); return }
        if t.commit != nil { return }
        let sig = workingTreeSignature(t)
        if sig == lastBuildSignature { return }
        lastBuildSignature = sig
        build(t)
    }

    private func sameTarget(_ a: DiffTarget?, _ b: DiffTarget) -> Bool {
        guard let a else { return false }
        return a.root == b.root && a.path == b.path && a.commit == b.commit
            && a.staged == b.staged && a.letter == b.letter
    }

    // 变更指纹：文件 mtime + 该仓库 HEAD 变化标记（reflog/HEAD 的 mtime，提交/切换都会变）。
    // 用 t.root 自身的 .git，单仓库/多仓库统一，不依赖 git.state（多仓库 root 为 nil）。
    private func workingTreeSignature(_ t: DiffTarget) -> String {
        let fileMtime = Self.mtime((t.root as NSString).appendingPathComponent(t.path))
        let gitDir = (t.root as NSString).appendingPathComponent(".git")
        let headMtime = Self.mtime((gitDir as NSString).appendingPathComponent("logs/HEAD"))
            ?? Self.mtime((gitDir as NSString).appendingPathComponent("HEAD"))
        return "\(fileMtime ?? 0)-\(headMtime ?? 0)"
    }

    private static func mtime(_ path: String) -> Double? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        return d.timeIntervalSince1970
    }

    private func build(_ t: DiffTarget) {
        guard !t.root.isEmpty else { diffState = .failed(t, "不是 Git 仓库"); return }
        diffSeq += 1
        let mine = diffSeq
        work.async { [weak self] in
            let r = DiffBuilder.build(target: t)
            DispatchQueue.main.async {
                guard let self, self.diffSeq == mine, self.isOpen, self.current == t else { return }
                if case .loaded(let nd) = r, case .loaded(let cur) = self.diffState, cur == nd { return }
                self.diffState = r
            }
        }
    }
}
