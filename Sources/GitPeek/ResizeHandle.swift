import SwiftUI
import AppKit

// 面板外侧边缘的宽度调整手柄（AppKit）：
// - 光标：左右双向箭头（tracking area，非激活面板也生效）
// - 拖拽：用屏幕绝对 X 算增量（参照系固定 → 不抖），按吸附侧决定加宽方向
struct ResizeHandle: NSViewRepresentable {
    let getWidth: () -> CGFloat
    let setWidth: (CGFloat) -> Void
    let minW: CGFloat
    let maxW: CGFloat

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let v = ResizeHandleNSView()
        v.configure(get: getWidth, set: setWidth, minW: minW, maxW: maxW)
        return v
    }
    func updateNSView(_ v: ResizeHandleNSView, context: Context) {
        v.configure(get: getWidth, set: setWidth, minW: minW, maxW: maxW)
    }
}

final class ResizeHandleNSView: NSView {
    private var getWidth: (() -> CGFloat)?
    private var setWidth: ((CGFloat) -> Void)?
    private var minW: CGFloat = 200
    private var maxW: CGFloat = 1000
    private var startScreenX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var tracking: NSTrackingArea?

    func configure(get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void,
                   minW: CGFloat, maxW: CGFloat) {
        self.getWidth = get; self.setWidth = set; self.minW = minW; self.maxW = maxW
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .inVisibleRect 动态跟随可见区域；.mouseMoved 让移动全程重设光标，避免被重置回箭头
        let t = NSTrackingArea(rect: .zero,
                               options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    // push/pop 强制光标：非 key 面板里 set() 会被前台应用/SwiftUI 覆盖
    private var cursorPushed = false
    private func pushCursor() { if !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true } }
    private func popCursor() { if cursorPushed { NSCursor.pop(); cursorPushed = false } }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) {
        if !(window?.isKeyWindow ?? false) { window?.makeKey() }  // 成 key 光标才生效
        pushCursor()
    }
    override func mouseMoved(with event: NSEvent) { pushCursor() }
    override func mouseExited(with event: NSEvent) { popCursor() }
    deinit { popCursor() }

    override func mouseDown(with event: NSEvent) {
        startWidth = getWidth?() ?? 0
        startScreenX = window?.convertPoint(toScreen: event.locationInWindow).x ?? 0
        pushCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        pushCursor()   // 拖动全程保持光标
        let cur = window.convertPoint(toScreen: event.locationInWindow).x
        // 吸右：向右拖变宽（+）；吸左：向左拖变宽（-）
        let sign: CGFloat = (Settings.shared.dockSide == .right) ? 1 : -1
        var w = startWidth + sign * (cur - startScreenX)
        w = min(max(w, minW), maxW)
        setWidth?(w)
    }
}
