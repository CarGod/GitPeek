# Changelog

## v0.3.0 — 2026-07-10

### 中文
- **新增：底部额度条。** 面板底部新增三条一目了然的用量进度条：
  - **5h / 周** — 直接读取 Claude Code 官方 `rate_limits`（通过 statusLine 钩子捕获），百分比与重置倒计时和 `/usage` 完全一致。首次需新开一个 Claude Code 会话让官方数据落盘。
  - **Fable** — 本周 Fable 用量（官方未把 Fable 窗口下发到 statusLine，故本地按 `~/.claude` 会话记录估算），显示为百分比 + 重置倒计时（复用官方周边界）。
- **新增：Fable 双击校准。** 双击 Fable 那一行，填入 `/usage` 里「Current week (Fable)」的真实百分比，GitPeek 按当前本地统计反推「周预算」，让这一格立即对齐官方数字；之后飘了再双击校一次即可。悬停该行可看原始 token / 预算。
- **新增：多仓库未推送提交徽标。** 多仓库列表里，每个仓库分支旁显示琥珀色 `↑N`，表示有 N 个本地已提交但尚未推送的提交（全部已推送则不显示，呼应 GRAPH 里「琥珀 = 本地未推送」的配色）。

### English
- **New: bottom usage bar.** Three at-a-glance usage meters at the panel bottom:
  - **5h / week** — read straight from Claude Code's official `rate_limits` (captured via the statusLine hook); the percentage and reset countdown match `/usage` exactly. Open a fresh Claude Code session once so the official data lands.
  - **Fable** — this week's Fable usage as a percentage + reset countdown (Claude Code doesn't forward the Fable window to statusLine, so it's estimated locally from `~/.claude` session logs; the countdown reuses the official weekly boundary).
- **New: double-click to calibrate Fable.** Double-click the Fable row and enter the real "Current week (Fable)" percentage from `/usage`; GitPeek back-computes the weekly budget so the bar matches. Re-calibrate anytime it drifts. Hover the row to see the raw token count / budget.
- **New: unpushed-commit badge.** In multi-repo mode, each repo shows an amber `↑N` next to its branch — N local commits committed but not yet pushed (hidden when all pushed; matches the "amber = local / not pushed" color used in the commit GRAPH).

## v0.2.0

- Multi-repo support: accordion list, per-repo branch display & switch.
- Watch the parent directory in multi-repo mode for instant repo detection.

## v0.1.0

- Initial release: a git status panel docked to the iTerm2 window — CHANGES, GRAPH, and a single-file diff viewer.
