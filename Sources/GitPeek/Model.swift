import SwiftUI

// 状态字母 → 颜色（ChangeEntry 与 CommitFileChange 共用，对齐 VSCode source control 直觉）
enum StatusPalette {
    static func color(for letter: String) -> Color {
        switch letter {
        case "M": return Color(red: 0.97, green: 0.74, blue: 0.36) // 修改 琥珀
        case "A", "U": return Color(red: 0.53, green: 0.85, blue: 0.55) // 新增/未跟踪 绿
        case "D": return Color(red: 0.95, green: 0.52, blue: 0.52) // 删除 红
        case "R", "C": return Color(red: 0.56, green: 0.74, blue: 0.97) // 重命名/复制 蓝
        case "!": return Color(red: 0.96, green: 0.44, blue: 0.44) // 冲突 红
        default: return Color(white: 0.6)
        }
    }
}

// 一个改动文件条目
struct ChangeEntry: Identifiable, Equatable {
    // 稳定且唯一的标识：内容派生（刷新时不变）→ 保住滚动位置；
    // 复合 staged+letter+path 避免同一 path 出现两行（如 git rm --cached）导致重复 id。
    var id: String { "\(staged ? "S" : "W")-\(letter)-\(path)" }
    var path: String          // 相对仓库根的完整路径
    var letter: String        // 展示用状态字母：M/A/D/U/R/!/?
    var staged: Bool          // 是否已暂存（进入 index）
    var oldPath: String? = nil // 重命名时的旧路径（id 不含它 → 不影响滚动不变量）

    var fileName: String { (path as NSString).lastPathComponent }
    var dirName: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d
    }

    var color: Color { StatusPalette.color(for: letter) }
}

// 某个提交里改动的一个文件（feature A：展开提交时用）
struct CommitFileChange: Identifiable, Equatable {
    var id: String { "\(letter)-\(path)" }   // 内容派生 id（不进合成 Equatable）
    var path: String
    var oldPath: String?      // 重命名时的旧路径
    var letter: String        // M/A/D/R/C

    var fileName: String { (path as NSString).lastPathComponent }
    var dirName: String {
        let d = (path as NSString).deletingLastPathComponent
        return d.isEmpty ? "" : d
    }
    var color: Color { StatusPalette.color(for: letter) }
}

// 一条提交记录
struct CommitEntry: Identifiable, Equatable {
    // 稳定标识：提交哈希唯一且不随刷新变化（计算属性 → 不进入合成的 Equatable）
    var id: String { hash }
    var hash: String
    var subject: String
    var refs: [String]        // 例如 ["main", "origin/main"]
    var pushed: Bool = true   // 是否已推送到上游（false = 本地未推送）
    var isHead: Bool = false  // 是否当前 HEAD
}

// 整个仓库快照
struct RepoState: Equatable {
    var root: String? = nil           // git 仓库根，nil = 当前目录不是 git 仓库
    var branch: String = ""
    var upstream: String = ""         // 上游分支，如 origin/main
    var ahead: Int = 0
    var behind: Int = 0
    var changes: [ChangeEntry] = []
    var commits: [CommitEntry] = []
    // 多仓库模式：当前目录不是仓库、但直接子目录里有仓库时，列出它们（自然序、确定性 → 不破坏防滚动重置）
    var availableRepos: [ChildRepo] = [] // depth-1 子仓库；非空=多仓库模式
    var reposParent: String? = nil       // availableRepos 所属父目录（cwd）

    var isRepo: Bool { root != nil }
    var isMulti: Bool { !availableRepos.isEmpty }
}

// 多仓库列表里的一个子仓库
struct ChildRepo: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var branch: String       // 当前分支（读 .git/HEAD 得到；worktree/detached 可能为空或短 sha）
    var name: String { (path as NSString).lastPathComponent }
}
