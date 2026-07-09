import SwiftUI
import AppKit

enum Palette {
    static let bg          = Color(red: 0.115, green: 0.115, blue: 0.13)
    static let headerBar   = Color(red: 0.155, green: 0.155, blue: 0.175)
    static let sectionBar  = Color(red: 0.145, green: 0.145, blue: 0.165)
    static let fileName    = Color(white: 0.94)
    static let dirPath     = Color(white: 0.56)
    static let sectionText = Color(white: 0.66)
    static let commitText  = Color(white: 0.84)
    static let border      = Color.white.opacity(0.09)
    static let hover       = Color.white.opacity(0.07)
    static let dot         = Color(red: 0.40, green: 0.60, blue: 0.90)
    static let badgeBlue   = Color(red: 0.22, green: 0.47, blue: 0.74)

    // 提交图配色与徽章统一：未推送=橙（同本地标签），已推送=紫（同远端标签）
    static let outgoingNode = Color(red: 0.93, green: 0.63, blue: 0.24)   // 未推送 橙
    static let outgoingLine = Color(red: 0.66, green: 0.46, blue: 0.20)   // 未推送 橙(暗)
    static let pushedNode    = Color(red: 0.60, green: 0.44, blue: 0.82)  // 已推送 紫
    static let pushedLine    = Color(red: 0.44, green: 0.33, blue: 0.60)  // 已推送 紫(暗)

    // 分支徽章：本地=橙黄，远端=紫色(带云图标)，tag=土黄
    static let localTag    = Color(red: 0.86, green: 0.58, blue: 0.20)   // 本地待提交 橙黄
    static let remoteTag   = Color(red: 0.53, green: 0.36, blue: 0.74)   // 已推送远端 紫
    static let tagTag      = Color(red: 0.46, green: 0.40, blue: 0.26)
}

struct PanelView: View {
    @ObservedObject var git: GitService
    @ObservedObject var coordinator: PanelCoordinator
    @State private var ratio: CGFloat = CGFloat(Settings.shared.splitRatio)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            if git.state.isRepo {
                content
            } else {
                emptyState
            }
        }
        .background(Palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Palette.border, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .overlay(alignment: Settings.shared.dockSide == .right ? .trailing : .leading) {
            ResizeHandle(
                getWidth: { CGFloat(Settings.shared.mainPanelWidth) },
                setWidth: { Settings.shared.mainPanelWidth = Double($0) },
                minW: 240, maxW: 900)
                .frame(width: 8)
        }
    }

    // MARK: - 顶部分支条

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.dot)
            Text(git.state.isRepo ? git.state.branch : "GitPeek")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Palette.fileName)
                .lineLimit(1)
            if git.state.isRepo && (git.state.ahead > 0 || git.state.behind > 0) {
                HStack(spacing: 7) {
                    if git.state.behind > 0 {
                        counter("arrow.down", git.state.behind)
                    }
                    if git.state.ahead > 0 {
                        counter("arrow.up", git.state.ahead)
                    }
                }
                .foregroundColor(Palette.sectionText)
            }
            Spacer()
            Button { git.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(Palette.sectionText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.headerBar)
    }

    private func counter(_ symbol: String, _ n: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text("\(n)").font(.system(size: 10.5, weight: .medium))
        }
    }

    // MARK: - 主体

    private var content: some View {
        GeometryReader { geo in
            let dividerH: CGFloat = 8
            let total = max(1, geo.size.height - dividerH)
            let clamped = min(max(ratio, 0.15), 0.85)
            let topH = clamped * total

            VStack(spacing: 0) {
                // 上：CHANGES（独立滚动）
                VStack(spacing: 0) {
                    sectionHeader("CHANGES", count: git.state.changes.count)
                    changesList
                }
                .frame(height: topH)
                .clipped()

                divider(total: total)

                // 下：GRAPH（独立滚动，占剩余空间）
                VStack(spacing: 0) {
                    sectionHeader("GRAPH", count: git.state.commits.count)
                    graphList
                }
                .frame(maxHeight: .infinity)
                .clipped()
            }
        }
    }

    private var changesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if git.state.changes.isEmpty {
                    Text("没有改动")
                        .font(.system(size: 11.5))
                        .foregroundColor(Palette.dirPath)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                } else {
                    ForEach(git.state.changes) { ChangeRow(entry: $0, coordinator: coordinator) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var graphList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(git.state.commits.enumerated()), id: \.element.hash) { _, c in
                    CommitRow(commit: c, coordinator: coordinator)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 可拖动分隔条（AppKit 实现：光标 + 丝滑拖拽）
    private func divider(total: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Palette.sectionBar)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.white.opacity(0.22))
                .frame(width: 28, height: 3)
            DividerHandle(
                total: total,
                currentRatio: { ratio },
                onChange: { ratio = $0 },
                onCommit: { Settings.shared.splitRatio = Double(ratio) }
            )
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
                .foregroundColor(Palette.sectionText)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                    .background(Capsule().fill(Palette.badgeBlue))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Palette.sectionBar)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 30))
                .foregroundColor(Palette.dirPath)
            Text("当前目录不是 Git 仓库")
                .font(.system(size: 12.5))
                .foregroundColor(Palette.sectionText)
            Text("在 iTerm2 里 cd 进一个 git 项目即可")
                .font(.system(size: 10.5))
                .foregroundColor(Palette.dirPath)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单行：改动文件

private struct ChangeRow: View {
    let entry: ChangeEntry
    @ObservedObject var coordinator: PanelCoordinator
    @State private var hovering = false

    private var target: DiffTarget { DiffTarget(change: entry) }
    private var selected: Bool { coordinator.isSelected(target) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(Palette.dirPath)
                .frame(width: 14)
            Text(entry.fileName)
                .font(.system(size: 12.5))
                .foregroundColor(Palette.fileName)
                .lineLimit(1)
                .layoutPriority(1)
            if !entry.dirName.isEmpty {
                Text(entry.dirName)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.dirPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(entry.letter)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(entry.color)
                .frame(minWidth: 12)
        }
        .padding(.horizontal, 12).padding(.vertical, 4.5)
        .background(selected ? Palette.hover.opacity(1.7) : (hovering ? Palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { coordinator.toggleDiff(target) }
    }
}

// MARK: - 单行：提交

private struct CommitRow: View {
    let commit: CommitEntry
    @ObservedObject var coordinator: PanelCoordinator
    @State private var headerHover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            GraphRail(pushed: commit.pushed, isHead: commit.isHead)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                headerContent
                    .contentShape(Rectangle())
                    .background(headerHover ? Palette.hover : Color.clear)
                    .onHover { headerHover = $0 }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            coordinator.toggleExpand(commit.hash)
                        }
                    }
                if coordinator.isExpanded(commit.hash) {
                    expansion
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private var headerContent: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: coordinator.isExpanded(commit.hash) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Palette.dirPath)
                .frame(width: 10)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 11.5))
                    .foregroundColor(commit.pushed ? Palette.commitText : Color(white: 0.95))
                    .lineLimit(2)
                if !commit.refs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(commit.refs, id: \.self) { RefBadge(ref: $0) }
                    }
                }
            }
            .padding(.vertical, 6)
            Spacer(minLength: 0)
            if !commit.pushed {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Palette.outgoingNode)
                    .padding(.top, 8)
            }
        }
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fs = coordinator.filesFor(commit.hash) {
                if fs.isEmpty {
                    Text("（无文件变更）")
                        .font(.system(size: 10.5))
                        .foregroundColor(Palette.dirPath)
                        .padding(.vertical, 4).padding(.leading, 2)
                } else {
                    ForEach(fs) { CommitFileRow(file: $0, hash: commit.hash, coordinator: coordinator) }
                }
            } else if coordinator.isLoadingFiles(commit.hash) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("载入中…").font(.system(size: 10.5)).foregroundColor(Palette.dirPath)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - 单行：某提交里的文件

private struct CommitFileRow: View {
    let file: CommitFileChange
    let hash: String
    @ObservedObject var coordinator: PanelCoordinator
    @State private var hovering = false

    private var target: DiffTarget { DiffTarget(commit: hash, file: file) }
    private var selected: Bool { coordinator.isSelected(target) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(Palette.dirPath)
                .frame(width: 12)
            Text(file.fileName)
                .font(.system(size: 11.5))
                .foregroundColor(Palette.fileName)
                .lineLimit(1)
                .layoutPriority(1)
            if !file.dirName.isEmpty {
                Text(file.dirName)
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.dirPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(file.letter)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(file.color)
                .frame(minWidth: 11)
        }
        .padding(.leading, 4).padding(.trailing, 2).padding(.vertical, 3)
        .background(selected ? Palette.hover.opacity(1.7) : (hovering ? Palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { coordinator.toggleDiff(target) }
    }
}

// 提交图左侧轨道：贯穿整行的竖线 + 节点
// 竖线与所有圆都以整条轨道的水平中心为轴 → 同轴对齐；外圈用 strokeBorder → 与圆点严格同心
private struct GraphRail: View {
    let pushed: Bool
    let isHead: Bool

    var body: some View {
        let nodeColor = pushed ? Palette.pushedNode : Palette.outgoingNode
        let lineColor = pushed ? Palette.pushedLine : Palette.outgoingLine
        let dot: CGFloat = pushed ? 8 : 9
        ZStack(alignment: .top) {
            // 竖线：2px、占满整行高度、居中于整条轨道（与上下相邻行相连）
            Rectangle()
                .fill(lineColor)
                .frame(width: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 节点：各圆同心（默认居中 ZStack），整体水平居中于整条轨道、贴顶对齐首行文字
            ZStack {
                if !pushed {
                    Circle().fill(nodeColor.opacity(0.22)).frame(width: 17, height: 17)
                }
                if isHead {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                        .frame(width: dot + 7, height: dot + 7)
                }
                Circle().fill(nodeColor).frame(width: dot, height: dot)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 分支/远端/标签徽章
private struct RefBadge: View {
    let ref: String

    var body: some View {
        let tag = ref.hasPrefix("tag:")
        let remote = !tag && ref.contains("/")
        let icon = tag ? "tag.fill" : (remote ? "cloud.fill" : "arrow.triangle.branch")
        let text = tag ? String(ref.dropFirst(4)).trimmingCharacters(in: .whitespaces) : ref
        let color = tag ? Palette.tagTag : (remote ? Palette.remoteTag : Palette.localTag)
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            Text(text).font(.system(size: 9, weight: .semibold)).fixedSize()
        }
        .foregroundColor(.white.opacity(0.95))
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(Capsule().fill(color))
    }
}
