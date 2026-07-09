import SwiftUI

// 要展示 diff 的目标：工作区文件（commit==nil）或某提交里的文件
struct DiffTarget: Equatable {
    var path: String
    var commit: String?       // nil = 工作区改动；否则是提交哈希
    var staged: Bool
    var letter: String        // 状态字母（决定用哪种 git 命令）
    var oldPath: String? = nil

    var fileName: String { (path as NSString).lastPathComponent }
    var dirName: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d
    }

    init(path: String, commit: String?, staged: Bool, letter: String, oldPath: String? = nil) {
        self.path = path; self.commit = commit; self.staged = staged
        self.letter = letter; self.oldPath = oldPath
    }
    init(change c: ChangeEntry) {
        self.init(path: c.path, commit: nil, staged: c.staged, letter: c.letter, oldPath: c.oldPath)
    }
    init(commit h: String, file f: CommitFileChange) {
        self.init(path: f.path, commit: h, staged: false, letter: f.letter, oldPath: f.oldPath)
    }
}

// diff 里的一行
struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case context, added, removed, hunk, noNewline }
    let id: Int               // 解析时顺序分配（diff 行不会重排）
    let kind: Kind
    let oldNum: Int?
    let newNum: Int?
    let text: String
    let highlighted: AttributedString   // 预算好的语法高亮（hunk/noNewline 为空）

    // 手写 ==：highlighted 由 text 唯一决定，不参与比较（省 no-op guard 的开销）
    static func == (l: DiffLine, r: DiffLine) -> Bool {
        l.id == r.id && l.kind == r.kind && l.oldNum == r.oldNum
            && l.newNum == r.newNum && l.text == r.text
    }
}

struct FileDiff: Equatable {
    let target: DiffTarget
    let lines: [DiffLine]
    let added: Int
    let removed: Int
    let truncated: Bool
    let maxDigits: Int
}

// diff 面板的状态机
enum DiffState: Equatable {
    case idle
    case loading(DiffTarget)
    case loaded(FileDiff)
    case empty(DiffTarget, String)
    case binary(DiffTarget)
    case conflict(DiffTarget)
    case tooLarge(DiffTarget)
    case failed(DiffTarget, String)
}

// 根据目标跑 git、解析成 FileDiff
enum DiffBuilder {
    static let maxUntrackedBytes = 2_000_000
    static let maxBodyLines = 3000
    static let wholeFileContext = "100000"   // 足够大的上下文 → 带出整个文件

    static func build(target t: DiffTarget, root: String) -> DiffState {
        // (1) 冲突/未合并文件：git 会输出 combined `diff --cc`，两列解析器渲染不了 → 占位
        if t.commit == nil && t.letter == "!" { return .conflict(t) }

        // (2) 未跟踪新文件：整文件当新增，先判大小
        if t.commit == nil && t.letter == "U" {
            let full = (root as NSString).appendingPathComponent(t.path)
            if let sz = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int,
               sz > maxUntrackedBytes {
                return .tooLarge(t)
            }
            guard let raw = Shell.gitDiff(["diff", "--no-color", "--no-index", "--", "/dev/null", t.path], root: root) else {
                return .failed(t, "diff 读取失败")
            }
            return parse(raw, target: t)
        }

        // (3) 提交里的文件（feature A）或工作区已跟踪文件（相对 HEAD = 暂存+未暂存合并）
        // 用超大 context 带出整个文件，改动部分高亮在原文里
        let ctx = "--unified=\(wholeFileContext)"
        var args: [String]
        if let h = t.commit {
            args = ["show", "--no-color", "--format=", "-M", ctx, h, "--", t.path]
            if let old = t.oldPath, old != t.path { args.append(old) }
        } else {
            args = ["diff", "--no-color", "-M", ctx, "HEAD", "--", t.path]
            if let old = t.oldPath, old != t.path { args.append(old) }
        }
        var raw = Shell.git(args, root: root)
        if raw == nil && t.commit == nil {
            // HEAD 不存在（空仓库首个提交前）等情况的兜底
            raw = Shell.git(t.staged ? ["diff", "--no-color", ctx, "--cached", "--", t.path]
                                     : ["diff", "--no-color", ctx, "--", t.path], root: root)
        }
        guard let raw else { return .failed(t, "diff 读取失败") }
        return parse(raw, target: t)
    }

    static func parse(_ raw: String, target t: DiffTarget) -> DiffState {
        if raw.isEmpty { return .empty(t, "无改动") }
        var lines: [DiffLine] = []
        var added = 0, removed = 0, maxNum = 0, oldN = 0, newN = 0
        var inHunk = false, sawHunk = false, truncated = false, seq = 0
        let cfg = Syntax.config(for: t.path)      // 语法高亮：语言配置 + 跨行块注释状态
        var inBlock = false
        let empty = AttributedString("")

        for rl in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rl)
            if line.hasSuffix("\r") { line.removeLast() }        // CRLF
            if line.hasPrefix("diff --cc") || line.hasPrefix("diff --combined") || line.hasPrefix("@@@") {
                return .conflict(t)                              // 合并 combined diff
            }
            if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                return .binary(t)
            }
            if line.hasPrefix("diff --git") { inHunk = false; continue }
            if line.hasPrefix("@@ ") {
                sawHunk = true; inHunk = true
                let (a, c) = parseHunk(line); oldN = a; newN = c
                maxNum = max(maxNum, a, c)
                seq += 1
                lines.append(DiffLine(id: seq, kind: .hunk, oldNum: nil, newNum: nil, text: line, highlighted: empty))
                continue
            }
            if !inHunk { continue }          // ---/+++/index 头不当作内容
            if line.isEmpty { continue }
            let m = line.first!
            let body = expandTabs(String(line.dropFirst()))
            switch m {
            case "+":
                seq += 1
                let hl = Syntax.highlight(body, cfg: cfg, inBlock: &inBlock)
                lines.append(DiffLine(id: seq, kind: .added, oldNum: nil, newNum: newN, text: body, highlighted: hl))
                newN += 1; added += 1
            case "-":
                seq += 1
                let hl = Syntax.highlight(body, cfg: cfg, inBlock: &inBlock)
                lines.append(DiffLine(id: seq, kind: .removed, oldNum: oldN, newNum: nil, text: body, highlighted: hl))
                oldN += 1; removed += 1
            case "\\":
                seq += 1
                lines.append(DiffLine(id: seq, kind: .noNewline, oldNum: nil, newNum: nil, text: "", highlighted: empty))
            default:
                seq += 1
                let hl = Syntax.highlight(body, cfg: cfg, inBlock: &inBlock)
                lines.append(DiffLine(id: seq, kind: .context, oldNum: oldN, newNum: newN, text: body, highlighted: hl))
                oldN += 1; newN += 1
            }
            maxNum = max(maxNum, oldN, newN)
            if lines.count >= maxBodyLines { truncated = true; break }
        }
        if !sawHunk { return .empty(t, "仅重命名 / 模式变更") }
        return .loaded(FileDiff(target: t, lines: lines, added: added, removed: removed,
                                truncated: truncated, maxDigits: max(1, String(maxNum).count)))
    }

    static func parseHunk(_ s: String) -> (Int, Int) {
        var a = 0, c = 0
        for p in s.split(separator: " ") {
            if p.hasPrefix("-") { a = Int(p.dropFirst().split(separator: ",").first ?? "") ?? 0 }
            if p.hasPrefix("+") { c = Int(p.dropFirst().split(separator: ",").first ?? "") ?? 0 }
        }
        return (a, c)
    }

    static func expandTabs(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: "    ")
    }
}
