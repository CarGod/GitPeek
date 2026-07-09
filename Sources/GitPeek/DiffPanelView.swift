import SwiftUI

enum DiffColor {
    // 加深的增删底色（对齐 GitHub/VSCode 暗色 diff 的观感），配左侧亮色条
    static let addBg = Color(red: 0.24, green: 0.60, blue: 0.32).opacity(0.30)
    static let delBg = Color(red: 0.82, green: 0.28, blue: 0.30).opacity(0.30)
    static let addEdge = Color(red: 0.36, green: 0.82, blue: 0.45)   // 左侧亮绿条
    static let delEdge = Color(red: 0.97, green: 0.44, blue: 0.46)   // 左侧亮红条
    static let addFg = Color(white: 0.95)
    static let delFg = Color(white: 0.95)
    static let ctxFg = Color(white: 0.70)
    static let addFgStrong = Color(red: 0.53, green: 0.88, blue: 0.55)
    static let delFgStrong = Color(red: 0.98, green: 0.50, blue: 0.52)
    static let hunkBg = Color(red: 0.16, green: 0.22, blue: 0.34).opacity(0.6)
    static let hunkFg = Color(red: 0.52, green: 0.66, blue: 0.92)
    static let faint = Color(white: 0.40)
}

private extension DiffState {
    var target: DiffTarget? {
        switch self {
        case .idle: return nil
        case .loading(let t), .binary(let t), .conflict(let t), .tooLarge(let t): return t
        case .loaded(let d): return d.target
        case .empty(let t, _), .failed(let t, _): return t
        }
    }
}

struct DiffPanelView: View {
    @ObservedObject var coordinator: PanelCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            content
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
                getWidth: { CGFloat(Settings.shared.diffPanelWidth) },
                setWidth: { Settings.shared.diffPanelWidth = Double($0) },
                minW: 300, maxW: 1100)
                .frame(width: 5)
        }
    }

    private var target: DiffTarget? { coordinator.diffState.target }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text").font(.system(size: 11)).foregroundColor(Palette.dirPath)
            Text(target?.fileName ?? "Diff")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Palette.fileName).lineLimit(1)
            if let t = target, !t.dirName.isEmpty {
                Text(t.dirName)
                    .font(.system(size: 10)).foregroundColor(Palette.dirPath)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if case .loaded(let d) = coordinator.diffState {
                HStack(spacing: 6) {
                    Text("+\(d.added)").foregroundColor(DiffColor.addFgStrong)
                    Text("−\(d.removed)").foregroundColor(DiffColor.delFgStrong)
                }
                .font(.system(size: 10.5, weight: .medium))
            }
            Button { coordinator.forceReloadDiff() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundColor(Palette.sectionText)
            Button { coordinator.closeDiff() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundColor(Palette.sectionText)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.headerBar)
    }

    // MARK: - 主体

    @ViewBuilder private var content: some View {
        switch coordinator.diffState {
        case .idle:
            Color.clear
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(_, let m):
            centered("folder.badge.questionmark", m)
        case .binary:
            centered("doc.zipper", "二进制文件，无法显示差异")
        case .conflict:
            centered("exclamationmark.triangle", "合并 / 冲突差异暂不支持逐行显示")
        case .tooLarge:
            centered("doc.badge.ellipsis", "文件过大，暂不显示差异")
        case .empty(_, let m):
            centered(nil, m)
        case .loaded(let d):
            DiffGrid(diff: d)
        }
    }

    private func centered(_ symbol: String?, _ text: String) -> some View {
        VStack(spacing: 9) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 30)).foregroundColor(Palette.dirPath)
            }
            Text(text)
                .font(.system(size: 12.5)).foregroundColor(Palette.sectionText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }
}

// MARK: - 行

private struct DiffLineRow: View {
    let line: DiffLine
    let numColWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 左侧亮色条：增=绿 / 删=红 / 上下文=透明（保持对齐）
            Rectangle().fill(edge).frame(width: 3)
            // 行号双列（旧/新），右对齐，固定宽
            HStack(spacing: 0) {
                Text(line.oldNum.map(String.init) ?? "")
                    .frame(width: numColWidth, alignment: .trailing)
                Text(line.newNum.map(String.init) ?? "")
                    .frame(width: numColWidth, alignment: .trailing)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(Palette.dirPath.opacity(0.85))
            .padding(.horizontal, 5)
            .overlay(Rectangle().fill(Palette.border).frame(width: 1), alignment: .trailing)

            // 代码内容，语法高亮 + 软换行
            Text(line.text.isEmpty ? AttributedString(" ") : line.highlighted)
                .font(.system(size: 11.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6).padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
    }

    private var bg: Color {
        switch line.kind {
        case .added: return DiffColor.addBg
        case .removed: return DiffColor.delBg
        default: return .clear
        }
    }
    private var edge: Color {
        switch line.kind {
        case .added: return DiffColor.addEdge
        case .removed: return DiffColor.delEdge
        default: return .clear
        }
    }
}

private struct HunkRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(DiffColor.hunkFg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(DiffColor.hunkBg)
            .overlay(Rectangle().fill(Palette.border).frame(height: 1), alignment: .top)
    }
}

private struct FaintRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .italic()
            .foregroundColor(DiffColor.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 2)
    }
}

// 强制关掉底层 NSScrollView 的系统滚动条（.scrollIndicators(.hidden) 在「始终显示滚动条」
// 的系统设置下会失效）。放进 ScrollView 内容里，向上找到 NSScrollView 关掉 scroller。
private struct HideNativeScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerHiderView { ScrollerHiderView() }
    func updateNSView(_ v: ScrollerHiderView, context: Context) { v.hideNow() }
}

private final class ScrollerHiderView: NSView {
    // 一进入窗口层级就隐藏，避免打开瞬间先闪出一条原生黑滚动条
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleHide() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleHide() }

    private func scheduleHide() {
        hideNow()
        for d in [0.02, 0.08, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.hideNow() }
        }
    }

    func hideNow() {
        var cur: NSView? = self
        while let c = cur {
            if let sv = c as? NSScrollView {
                sv.scrollerStyle = .overlay        // overlay：滚动条浮在内容上，不预留宽度
                sv.autohidesScrollers = true
                sv.hasVerticalScroller = false
                sv.hasHorizontalScroller = false
                sv.verticalScroller?.isHidden = true
                sv.tile()                          // 立刻重新布局，回收滚动条预留的那列宽度
                return
            }
            cur = c.superview
        }
    }
}

// 直接读底层 NSScrollView 的真实几何（内容高度 / 滚动偏移 / 视口高度）——
// 比 SwiftUI 的 GeometryReader+preference 在 ScrollView 里可靠得多
private struct ScrollMetricsReader: NSViewRepresentable {
    let onChange: (_ content: CGFloat, _ offset: CGFloat, _ viewport: CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.onChange = onChange
        DispatchQueue.main.async { context.coordinator.attach(from: v) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        // 注意：不要在这里调 report()，否则 report→改 @State→重渲染→updateNSView→report 会形成反馈震荡
        context.coordinator.onChange = onChange
    }
    func makeCoordinator() -> Coord { Coord() }

    final class Coord {
        weak var scrollView: NSScrollView?
        var onChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private var last: (CGFloat, CGFloat, CGFloat) = (-1, -1, -1)

        func attach(from v: NSView) {
            var cur: NSView? = v
            while let c = cur {
                if let sv = c as? NSScrollView { scrollView = sv; break }
                cur = c.superview
            }
            guard let sv = scrollView else { return }
            sv.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(changed),
                name: NSView.boundsDidChangeNotification, object: sv.contentView)
            report()
            // 内容布局可能稍晚完成，补两拍
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.report() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.report() }
        }

        @objc func changed() { report() }

        func report() {
            guard let sv = scrollView else { return }
            let content = sv.documentView?.frame.height ?? 0
            let viewport = sv.contentView.bounds.height
            let flipped = sv.documentView?.isFlipped ?? true
            let originY = sv.contentView.bounds.origin.y
            let offset = flipped ? originY : max(0, content - viewport - originY)
            // 去抖：变化 <1px 不回调，避免反馈震荡
            if abs(content - last.0) < 1, abs(offset - last.1) < 1, abs(viewport - last.2) < 1 { return }
            last = (content, offset, viewport)
            onChange?(content, offset, viewport)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

// diff 主体：内容滚动区（隐藏系统滚动条）+ 右侧「概览条=滚动条」二合一
private struct DiffGrid: View {
    let diff: FileDiff
    @State private var contentH: CGFloat = 1
    @State private var offset: CGFloat = 0
    @State private var viewportH: CGFloat = 1

    var body: some View {
        let numColWidth = max(16, CGFloat(diff.maxDigits) * 7 + 4)
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { line in
                            Group {
                                switch line.kind {
                                case .hunk: HunkRow(text: line.text)
                                case .noNewline: FaintRow(text: "No newline at end of file")
                                default: DiffLineRow(line: line, numColWidth: numColWidth)
                                }
                            }
                            .id(line.id)
                        }
                        if diff.truncated {
                            FaintRow(text: "… diff 已截断（前 \(DiffBuilder.maxBodyLines) 行）")
                        }
                    }
                    .background(HideNativeScroller().frame(width: 0, height: 0))
                    .background(ScrollMetricsReader { c, o, v in
                        contentH = c; offset = o; viewportH = v
                    })
                }
                .scrollIndicators(.hidden)
                .textSelection(.enabled)

                OverviewScrollbar(lines: diff.lines, contentHeight: contentH,
                                  offset: offset, viewportHeight: viewportH) { frac in
                    let idx = min(diff.lines.count - 1, max(0, Int(frac * CGFloat(diff.lines.count))))
                    proxy.scrollTo(diff.lines[idx].id, anchor: .top)
                }
                .frame(width: 18)
            }
        }
    }
}

// 概览条 + 滚动条二合一：整文件比例的改动 tick + 反映可见范围的滑块，点击/拖动即滚动
private struct OverviewScrollbar: View {
    let lines: [DiffLine]
    let contentHeight: CGFloat
    let offset: CGFloat
    let viewportHeight: CGFloat
    let onScrub: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let barH = geo.size.height
            let vH = min(viewportHeight, contentHeight)
            let thumbFrac = contentHeight > 0 ? min(1, vH / contentHeight) : 1
            let thumbH = max(28, thumbFrac * barH)
            let maxOffset = max(1, contentHeight - vH)
            let thumbY = min(barH - thumbH, max(0, (offset / maxOffset) * (barH - thumbH)))

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Palette.sectionBar)
                // 改动 tick
                Canvas { ctx, size in
                    let n = lines.count
                    guard n > 0 else { return }
                    let rowH = max(1.5, size.height / CGFloat(n))
                    for (idx, line) in lines.enumerated() {
                        let color: Color?
                        switch line.kind {
                        case .added: color = DiffColor.addEdge
                        case .removed: color = DiffColor.delEdge
                        default: color = nil
                        }
                        guard let color else { continue }
                        let y = size.height * CGFloat(idx) / CGFloat(n)
                        ctx.fill(Path(CGRect(x: 2, y: y, width: size.width - 4, height: rowH)),
                                 with: .color(color))
                    }
                }
                // 当前可见范围（VSCode 式半透明滑块）：高度=可见比例，位置=滚动位置；仅在可滚动时显示
                if contentHeight > viewportHeight + 2 {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.5))
                        .frame(width: geo.size.width - 2, height: thumbH)
                        .offset(x: 1, y: thumbY)
                }
            }
            .overlay(Rectangle().fill(Palette.border).frame(width: 1), alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onScrub(min(max(v.location.y / barH, 0), 1)) }
            )
        }
    }
}
