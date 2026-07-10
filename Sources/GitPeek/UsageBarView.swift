import SwiftUI
import AppKit

// 窗口底部的额度条：三条统一的彩色进度条。
//  · 5h  = 官方当前(5小时)用量%     + 重置倒计时
//  · 周  = 官方本周(7天)用量%       + 重置倒计时
//  · Fable = 本地统计的本周用量 ÷ 可调「周预算」= 百分比 + 重置倒计时(statusLine 不下发 Fable 窗口,故本地估算;倒计时复用官方周边界)
// 数据没到时也照样显示空进度条(占位),保持三条一致的视觉;倒计时用 TimelineView 每 30s 自走。
struct UsageBar: View {
    @ObservedObject var usage: UsageService

    private let labelW: CGFloat = 50   // 左侧标签列宽,让三条进度条从同一 x 起始

    var body: some View {
        let s = usage.stats
        VStack(spacing: 0) {
            Rectangle().fill(Palette.border).frame(height: 1)
            TimelineView(.periodic(from: Date(), by: 30)) { ctx in
                let now = ctx.date
                VStack(spacing: 6) {
                    barRow(label: "5h", icon: nil,
                           fill: s.fiveHour.map { Double($0.percent) / 100 },
                           color: s.fiveHour.map { barColor($0.percent) } ?? .clear,
                           right: s.fiveHour.map { "\($0.percent)%" } ?? "—",
                           sub: subText(s.fiveHour, hasOfficial: s.hasOfficial, now: now))
                    barRow(label: "周", icon: nil,
                           fill: s.sevenDay.map { Double($0.percent) / 100 },
                           color: s.sevenDay.map { barColor($0.percent) } ?? .clear,
                           right: s.sevenDay.map { "\($0.percent)%" } ?? "—",
                           sub: subText(s.sevenDay, hasOfficial: s.hasOfficial, now: now))
                    let fableFrac = min(1, Double(s.fableTokens) / max(1, Settings.shared.fableWeeklyBudget))
                    barRow(label: "Fable", icon: "sparkles",
                           fill: fableFrac,
                           color: Palette.remoteTag,                 // 紫,呼应 Fable 旗舰模型
                           right: "\(Int((fableFrac * 100).rounded()))%",
                           sub: fableSub(s, now: now),
                           help: fableHelp(s),
                           onDoubleClick: { promptFableCalibration() })
                    if !s.hasOfficial { waitingHint }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Palette.headerBar)
    }

    // MARK: - 一条进度条行

    private func barRow(label: String, icon: String?, fill: Double?, color: Color,
                        right: String, sub: String, help: String? = nil,
                        onDoubleClick: (() -> Void)? = nil) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 9.5)).foregroundColor(color)
                }
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Palette.sectionText)
            }
            .frame(width: labelW, alignment: .leading)

            bar(fill: fill, color: color)

            Text(right)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(fill == nil ? Palette.dirPath : Palette.fileName)
                .frame(width: 38, alignment: .trailing)

            Text(sub)
                .font(.system(size: 9.5))
                .foregroundColor(Palette.dirPath)
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .contentShape(Rectangle())                          // 整行(含空白)可点，不只文字
        .help(help ?? "")   // 空串 = 不显示 tooltip；Fable 行用它展示原始 token 估算 + 预算
        .onTapGesture(count: 2) { onDoubleClick?() }         // 仅 Fable 行传了回调，其余为 no-op
    }

    @ViewBuilder private func bar(fill: Double?, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))          // 轨道(空槽也可见)
                if let f = fill, f > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geo.size.width * CGFloat(min(max(f, 0), 1))))
                }
            }
        }
        .frame(height: 5)
        .frame(maxWidth: .infinity)
    }

    private var waitingHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle").font(.system(size: 8.5))
            Text("新开一个 claude 会话即可显示官方 5h / 周")
                .font(.system(size: 8.5))
            Spacer(minLength: 0)
        }
        .foregroundColor(Palette.dirPath.opacity(0.85))
        .padding(.top, 1)
    }

    // MARK: - 辅助

    private func barColor(_ p: Int) -> Color {
        if p >= 85 { return Color(red: 0.90, green: 0.33, blue: 0.33) }   // 红：快到顶
        if p >= 60 { return Color(red: 0.95, green: 0.66, blue: 0.24) }   // 黄：留意
        return Color(red: 0.30, green: 0.74, blue: 0.45)                  // 绿：宽裕
    }

    // 右侧副文本：有数据显示倒计时；没数据显示「等待」。
    private func subText(_ w: RateWindow?, hasOfficial: Bool, now: Date) -> String {
        guard let w else { return hasOfficial ? "" : "等待" }
        guard let r = w.resetsAt else { return "" }
        return "⟳ " + countdown(to: r, from: now)
    }

    private func countdown(to date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    // Fable 副文本：有官方周重置时间就显示倒计时（和 5h/周 一致）；官方数据还没到时先标「本周」。
    // Fable 周窗口与官方 7 天窗口同一每周边界，故直接复用 sevenDay.resetsAt。
    private func fableSub(_ s: UsageStats, now: Date) -> String {
        if let r = s.sevenDay?.resetsAt { return "⟳ " + countdown(to: r, from: now) }
        return "本周"
    }

    // 悬停提示：保留原始 token 估算 + 预算，方便对照 /usage 校准 fableWeeklyBudget。
    private func fableHelp(_ s: UsageStats) -> String {
        let budget = Settings.shared.fableWeeklyBudget
        return "Fable 本周约 \(fmtTokens(s.fableTokens)) / 预算 \(fmtTokens(Int(budget)))（本地估算，非官方；双击此行按 /usage 校准）"
    }

    // 双击 Fable 行：填入 /usage 里「Current week (Fable)」的真实百分比，据当前本地 token 反推周预算，
    // 让这一格立刻对齐 /usage；之后随 token 增长继续走，飘了再双击校一次即可。
    private func promptFableCalibration() {
        let tokens = usage.stats.fableTokens
        let alert = NSAlert()
        alert.messageText = "校准 Fable 用量"
        alert.informativeText = """
        在 Claude Code 里输入 /usage，把「Current week (Fable)」显示的百分比填进来。
        本地本周已统计约 \(fmtTokens(tokens)) tokens，将据此反推周预算。
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 210, height: 24))
        field.placeholderString = "例如 3  (表示 3%)"
        let curPct = Int((min(1, Double(tokens) / max(1, Settings.shared.fableWeeklyBudget)) * 100).rounded())
        field.stringValue = "\(curPct)"
        alert.accessoryView = field
        alert.addButton(withTitle: "校准")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let pct = Double(raw), pct > 0, pct <= 100, tokens > 0 else { return }
        Settings.shared.fableWeeklyBudget = Double(tokens) / (pct / 100)
        usage.refresh()
    }

    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
