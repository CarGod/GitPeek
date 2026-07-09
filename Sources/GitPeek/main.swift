import AppKit

// GitPeek —— 吸附在 iTerm2 窗口右侧的 git 状态面板
// 菜单栏 agent 程序（无 Dock 图标）。

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory：有窗口但不在 Dock 显示、不抢主菜单栏
app.setActivationPolicy(.accessory)
app.run()
