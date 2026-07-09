import AppKit
import SwiftUI
import ApplicationServices
import Combine

// 可成为 key 的浮动面板：让内部 ScrollView 能接收滚动/交互，
// 但因为是 nonactivatingPanel，成为 key 不会激活本 App，也不抢 iTerm2 的活跃状态。
final class FollowerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var diffPanel: NSPanel!
    private let git = GitService()
    private lazy var coordinator = PanelCoordinator(git: git)
    private var follower: WindowFollower!
    private var cwdTimer: Timer?
    private var axTimer: Timer?
    private var lastFrame: CGRect = .zero
    private var lastSide: DockSide = Settings.shared.dockSide
    private var lastDiffFrame: CGRect = .zero
    private var diffCancellable: AnyCancellable?
    private var dockLeftItem: NSMenuItem?
    private var dockRightItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== launch === AXTrusted=\(AXIsProcessTrusted()) bundleID=\(Bundle.main.bundleIdentifier ?? "nil")")
        setupStatusItem()
        setupPanel()
        setupDiffPanel()
        setupFollower()
        observeDiff()

        // 文件内容变了但 porcelain 状态没变时，也让已打开的 diff 面板实时更新
        git.didRefresh = { [weak coordinator] in coordinator?.reloadDiffIfNeeded() }

        // iTerm2 激活时立刻刷新目录
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // 定时轮询当前目录（抓 cd 切目录）
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.git.refresh() }
        RunLoop.main.add(t, forMode: .common)
        cwdTimer = t

        ensureAccessibility()
        git.refresh()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "GitPeek")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "刷新", action: #selector(refreshNow), keyEquivalent: "r")

        let sideMenu = NSMenu()
        let leftItem = NSMenuItem(title: "吸附到左侧", action: #selector(setDockLeft), keyEquivalent: "")
        let rightItem = NSMenuItem(title: "吸附到右侧", action: #selector(setDockRight), keyEquivalent: "")
        dockLeftItem = leftItem
        dockRightItem = rightItem
        sideMenu.addItem(leftItem)
        sideMenu.addItem(rightItem)
        let sideParent = NSMenuItem(title: "吸附方向", action: nil, keyEquivalent: "")
        sideParent.submenu = sideMenu
        menu.addItem(sideParent)

        menu.addItem(.separator())
        menu.addItem(withTitle: "辅助功能权限设置…", action: #selector(openAXSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 GitPeek", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        for item in sideMenu.items { item.target = self }
        statusItem.menu = menu
        updateDockSideChecks()
    }

    private func updateDockSideChecks() {
        dockLeftItem?.state = (Settings.shared.dockSide == .left) ? .on : .off
        dockRightItem?.state = (Settings.shared.dockSide == .right) ? .on : .off
    }

    // MARK: - 浮动面板

    private func setupPanel() {
        panel = FollowerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: PanelView(git: git, coordinator: coordinator))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host)
    }

    // MARK: - Diff 面板（第二个吸附窗口）

    private func setupDiffPanel() {
        diffPanel = FollowerPanel(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(Settings.shared.diffPanelWidth), height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        diffPanel.level = .floating
        diffPanel.isFloatingPanel = true
        diffPanel.hidesOnDeactivate = false
        diffPanel.becomesKeyOnlyIfNeeded = true
        diffPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        diffPanel.hasShadow = true
        diffPanel.backgroundColor = .clear
        diffPanel.isOpaque = false
        diffPanel.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: DiffPanelView(coordinator: coordinator))
        host.frame = diffPanel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        diffPanel.contentView?.addSubview(host)
    }

    // 观察 diff 是否打开 → 显隐并即时定位
    private func observeDiff() {
        diffCancellable = coordinator.$isOpen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard let self else { return }
                if open {
                    if self.lastFrame != .zero {
                        self.positionDiffPanel(mainFrame: self.lastFrame, side: self.lastSide)
                        if self.panel.isVisible {
                            self.diffPanel.order(.above, relativeTo: self.panel.windowNumber)
                        }
                    }
                } else {
                    if self.diffPanel.isVisible { self.diffPanel.orderOut(nil) }
                    self.lastDiffFrame = .zero
                }
            }
    }

    private func positionDiffPanel(mainFrame m: CGRect, side: DockSide) {
        guard m != .zero else { return }
        let f = diffFrame(forMain: m, side: side)
        if f != lastDiffFrame {
            diffPanel.setFrame(f, display: true)
            lastDiffFrame = f
        }
    }

    private func diffFrame(forMain m: CGRect, side: DockSide) -> CGRect {
        let w = CGFloat(Settings.shared.diffPanelWidth)
        let y = m.origin.y
        let h = m.height
        var x = (side == .right) ? m.maxX : m.minX - w
        var effSide = side
        if let s = screenContaining(m) {
            let vf = s.visibleFrame
            // 外侧放不下就翻到另一侧
            if side == .right, x + w > vf.maxX + 1 { x = m.minX - w; effSide = .left }
            if side == .left, x < vf.minX - 1 { x = m.maxX; effSide = .right }
            // 只在外侧空隙内夹紧，绝不压到主面板上
            if effSide == .right {
                x = min(max(x, m.maxX), vf.maxX - w)
            } else {
                x = min(max(x, vf.minX), m.minX - w)
            }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func screenContaining(_ r: CGRect) -> NSScreen? {
        let mid = CGPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
    }

    // MARK: - 跟随

    private func setupFollower() {
        follower = WindowFollower { [weak self] frame, visible, side in
            guard let self else { return }
            if let frame, visible {
                if frame != self.lastFrame {
                    self.panel.setFrame(frame, display: true)
                    self.lastFrame = frame
                }
                if !self.panel.isVisible {
                    self.panel.orderFrontRegardless()
                    Log.once("panelvis", "panel -> SHOW at \(frame)")
                }
                // diff 面板：贴主面板外侧、跟随
                self.lastSide = side
                if self.coordinator.isOpen {
                    self.positionDiffPanel(mainFrame: frame, side: side)
                    if !self.diffPanel.isVisible {
                        self.diffPanel.order(.above, relativeTo: self.panel.windowNumber)
                    }
                }
            } else {
                if self.panel.isVisible {
                    self.panel.orderOut(nil)
                    Log.once("panelvis", "panel -> HIDE")
                }
                if self.diffPanel.isVisible { self.diffPanel.orderOut(nil) }
            }
        }
    }

    // MARK: - 权限

    private func ensureAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            Log.write("AX trusted at launch -> follower.start()")
            follower.start()
        } else {
            Log.write("AX NOT trusted -> waiting for grant (polling)")
            // 未授权：轮询等待用户在系统设置里打开
            let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self?.axTimer = nil
                    self?.follower.start()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            axTimer = t
        }
    }

    // MARK: - 动作

    @objc private func appActivated(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier == WindowFollower.itermBundleID {
            git.refresh()
        }
    }

    @objc private func refreshNow() { git.refresh() }

    @objc private func setDockLeft() {
        Settings.shared.dockSide = .left
        updateDockSideChecks()
        lastFrame = .zero        // 强制下一帧重新定位
        lastDiffFrame = .zero
    }

    @objc private func setDockRight() {
        Settings.shared.dockSide = .right
        updateDockSideChecks()
        lastFrame = .zero
        lastDiffFrame = .zero
    }

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
