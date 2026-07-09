import AppKit
import ApplicationServices

// 追踪 iTerm2 前窗口的位置，算出面板应吸附到的位置。
// 通过定时轮询（AX 读取很轻），把「目标 frame + 是否可见」回调出去。
final class WindowFollower {
    static let itermBundleID = "com.googlecode.iterm2"

    var panelWidth: CGFloat = 340
    var gap: CGFloat = 0   // 面板与终端窗口的间隙

    private var timer: Timer?
    private let onUpdate: (_ frame: CGRect?, _ visible: Bool, _ side: DockSide) -> Void

    init(onUpdate: @escaping (_ frame: CGRect?, _ visible: Bool, _ side: DockSide) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 每帧

    private func tick() {
        guard let iterm = NSRunningApplication.runningApplications(
            withBundleIdentifier: WindowFollower.itermBundleID).first else {
            Log.once("tick", "tick: iTerm2 not running")
            onUpdate(nil, false, Settings.shared.dockSide)
            return
        }

        // iTerm2 或我们自己在前台时才显示（点面板不会隐藏）
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let visible = (frontID == WindowFollower.itermBundleID)
            || (frontID == Bundle.main.bundleIdentifier)

        guard let axRect = focusedWindowAXRect(pid: iterm.processIdentifier) else {
            Log.once("tick", "tick: got iTerm2 pid=\(iterm.processIdentifier) but AX rect=nil (front=\(frontID ?? "?")) axTrusted=\(AXIsProcessTrusted())")
            onUpdate(nil, false, Settings.shared.dockSide)
            return
        }
        let (target, side) = dockedFrame(forITermAX: axRect)
        Log.once("tick", "tick: axRect=\(axRect) target=\(target) visible=\(visible) front=\(frontID ?? "?")")
        onUpdate(target, visible, side)
    }

    // 读 iTerm2 焦点窗口的 AX 矩形（原点在屏幕左上、Y 向下）
    private func focusedWindowAXRect(pid: pid_t) -> CGRect? {
        let appEl = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        if err != .success || winRef == nil {
            // 退回到窗口列表第一个
            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let wins = winsRef as? [AXUIElement], let first = wins.first else { return nil }
            winRef = first
        }
        guard let win = winRef else { return nil }
        let winEl = win as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winEl, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(winEl, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 50, size.height > 50 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    // 把 iTerm2 的 AX 矩形，转成面板应处的 AppKit 矩形（原点左下、Y 向上）；
    // 同时回传「翻转后实际使用的吸附侧」，供 diff 面板落到正确的外侧。
    private func dockedFrame(forITermAX axRect: CGRect) -> (CGRect, DockSide) {
        let H = Self.flipReferenceHeight()
        // iTerm2 窗口在 AppKit 坐标下
        let itermAppKit = CGRect(
            x: axRect.origin.x,
            y: H - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height)

        let y = itermAppKit.origin.y
        let w = CGFloat(Settings.shared.mainPanelWidth)   // 可调宽度（持久化）
        let h = itermAppKit.height
        let side = Settings.shared.dockSide

        let rightX = itermAppKit.maxX + gap
        let leftX = itermAppKit.origin.x - w - gap
        var x = (side == .right) ? rightX : leftX
        var effective = side

        // 越界就翻到另一边（并记录实际用的侧）
        if let screen = screen(containing: itermAppKit) {
            let vf = screen.visibleFrame
            if side == .right, rightX + w > vf.maxX + 1 { x = leftX; effective = .left }
            if side == .left, leftX < vf.minX - 1 { x = rightX; effective = .right }
        }
        return (CGRect(x: x, y: y, width: w, height: h), effective)
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
    }

    // 翻转基准：含全局原点(0,0)的主屏高度
    static func flipReferenceHeight() -> CGFloat {
        if let s = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return s.frame.height
        }
        return NSScreen.main?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
    }
}
