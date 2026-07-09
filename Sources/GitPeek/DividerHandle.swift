import SwiftUI
import AppKit

// 分隔条的 AppKit 实现：
// - 光标：用 tracking area 的 cursorUpdate，在非激活浮动面板里也能生效
// - 拖拽：用窗口绝对坐标(locationInWindow)算增量，参照系不随分隔条移动 → 不抖
struct DividerHandle: NSViewRepresentable {
    var total: CGFloat
    var currentRatio: () -> CGFloat
    var onChange: (CGFloat) -> Void
    var onCommit: () -> Void

    func makeNSView(context: Context) -> DividerNSView {
        let v = DividerNSView()
        v.configure(total: total, current: currentRatio, change: onChange, commit: onCommit)
        return v
    }

    func updateNSView(_ v: DividerNSView, context: Context) {
        v.configure(total: total, current: currentRatio, change: onChange, commit: onCommit)
    }
}

final class DividerNSView: NSView {
    private var total: CGFloat = 1
    private var currentRatio: (() -> CGFloat)?
    private var onChange: ((CGFloat) -> Void)?
    private var onCommit: (() -> Void)?

    private var startWinY: CGFloat = 0
    private var startRatio: CGFloat = 0.5
    private var tracking: NSTrackingArea?

    func configure(total: CGFloat,
                   current: @escaping () -> CGFloat,
                   change: @escaping (CGFloat) -> Void,
                   commit: @escaping () -> Void) {
        self.total = total
        self.currentRatio = current
        self.onChange = change
        self.onCommit = commit
    }

    // MARK: - 光标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // 加 .mouseMoved：移动全程反复重设光标，避免被系统/SwiftUI 重置回箭头
        let t = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // 用 push/pop 强制光标：非 key 面板里 set() 会被前台应用/SwiftUI 覆盖，push 压栈强制生效
    private var cursorPushed = false
    private func pushCursor() { if !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true } }
    private func popCursor() { if cursorPushed { NSCursor.pop(); cursorPushed = false } }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }
    override func mouseEntered(with event: NSEvent) {
        if !(window?.isKeyWindow ?? false) { window?.makeKey() }  // 成 key 光标才生效
        pushCursor()
    }
    override func mouseMoved(with event: NSEvent) { pushCursor() }
    override func mouseExited(with event: NSEvent) { popCursor() }
    deinit { popCursor() }

    // MARK: - 拖拽（窗口坐标，稳定参照系）

    override func mouseDown(with event: NSEvent) {
        startWinY = event.locationInWindow.y
        startRatio = currentRatio?() ?? 0.5
        pushCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        pushCursor()   // 拖动全程保持光标
        // 窗口坐标 Y 向上；鼠标下移 → dy<0 → 上半(CHANGES)变高
        let dy = event.locationInWindow.y - startWinY
        var r = startRatio - dy / max(total, 1)
        r = min(max(r, 0.15), 0.85)
        onChange?(r)
    }

    override func mouseUp(with event: NSEvent) {
        onCommit?()
    }
}
