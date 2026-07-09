import SwiftUI
import Combine

// 统一持有 feature A（展开状态 + 每提交文件缓存）和 feature B（diff 选中 + 文档）的 UI 状态。
// 所有这些状态都放这里、绝不进 RepoState —— 保住「内容不变则不重赋 state」的防滚动重置不变量。
// 沿用 GitService 的模式：后台队列跑 git，回主线程发布。不要标 @MainActor。
final class PanelCoordinator: ObservableObject {
    // Feature A：提交展开
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var files: [String: [CommitFileChange]] = [:]
    @Published private(set) var loadingFiles: Set<String> = []
    // Feature B：diff 面板
    @Published private(set) var isOpen: Bool = false
    @Published private(set) var diffState: DiffState = .idle

    private unowned let git: GitService          // AppDelegate 持有两者整个生命周期 → 无循环引用
    private let work = DispatchQueue(label: "gitpeek.coord", qos: .userInitiated)
    private var diffSeq = 0
    private var current: DiffTarget?
    private var openedRoot: String?              // 打开 diff 时所在仓库（切仓库保护）

    init(git: GitService) { self.git = git }

    // MARK: - 选中高亮（视图读）

    // 按 path + commit 判定选中（不用整个 DiffTarget，避免 git add 改了 staged/letter 后高亮丢失）
    func isSelected(_ t: DiffTarget) -> Bool {
        isOpen && current?.path == t.path && current?.commit == t.commit
    }

    // MARK: - Feature A

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
                // 只在成功（非 nil）时缓存；git 瞬时失败则留空以便重展开重试
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

    // MARK: - Feature B（主线程调用）

    private var lastBuildSignature: String?

    func openDiff(_ t: DiffTarget) {
        current = t
        openedRoot = git.state.root
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

    // 头部刷新按钮
    func forceReloadDiff() {
        guard isOpen, let t = current else { return }
        if git.state.root != openedRoot { closeDiff(); return }
        lastBuildSignature = t.commit == nil ? workingTreeSignature(t) : nil
        build(t)
    }

    // 每次刷新周期自动调用；提交 diff 不可变、内容未变都跳过（不空跑 git）
    func reloadDiffIfNeeded() {
        guard isOpen, let t = current else { return }
        if git.state.root != openedRoot { closeDiff(); return }
        if t.commit != nil { return }
        let sig = workingTreeSignature(t)
        if sig == lastBuildSignature { return }   // 文件 mtime 和 HEAD 都没变 → 跳过
        lastBuildSignature = sig
        build(t)
    }

    private func sameTarget(_ a: DiffTarget?, _ b: DiffTarget) -> Bool {
        a?.path == b.path && a?.commit == b.commit
    }

    // 工作区文件的廉价变更指纹：文件 mtime + 当前 HEAD 短哈希（都不额外跑 git）
    private func workingTreeSignature(_ t: DiffTarget) -> String {
        let root = openedRoot ?? git.state.root ?? ""
        let full = (root as NSString).appendingPathComponent(t.path)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: full))?[.modificationDate] as? Date
        let head = git.state.commits.first?.hash ?? ""
        return "\(mtime?.timeIntervalSince1970 ?? 0)-\(head)"
    }

    private func build(_ t: DiffTarget) {
        guard let root = openedRoot ?? git.state.root else {
            diffState = .failed(t, "不是 Git 仓库"); return
        }
        diffSeq += 1
        let mine = diffSeq
        work.async { [weak self] in
            let r = DiffBuilder.build(target: t, root: root)
            DispatchQueue.main.async {
                guard let self, self.diffSeq == mine, self.isOpen, self.current == t else { return }
                // no-op guard：内容相同的 diff 不重赋 → diff 面板不重置滚动
                if case .loaded(let nd) = r, case .loaded(let cur) = self.diffState, cur == nd { return }
                self.diffState = r
            }
        }
    }
}
