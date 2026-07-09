import Foundation

enum DockSide: String {
    case left
    case right
}

// 简单的偏好存储（UserDefaults）
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var dockSide: DockSide {
        get { DockSide(rawValue: d.string(forKey: "dockSide") ?? "right") ?? .right }
        set { d.set(newValue.rawValue, forKey: "dockSide") }
    }

    // CHANGES 区占上半部分的比例（0.15~0.85），默认 0.5 各占一半
    var splitRatio: Double {
        get { (d.object(forKey: "splitRatio") as? Double) ?? 0.5 }
        set { d.set(min(max(newValue, 0.15), 0.85), forKey: "splitRatio") }
    }

    // 主面板宽度（可拖拽调整并记住）
    var mainPanelWidth: Double {
        get { (d.object(forKey: "mainPanelWidth") as? Double) ?? 340 }
        set { d.set(min(max(newValue, 240), 900), forKey: "mainPanelWidth") }
    }

    // diff 面板宽度
    var diffPanelWidth: Double {
        get { (d.object(forKey: "diffPanelWidth") as? Double) ?? 460 }
        set { d.set(min(max(newValue, 300), 1100), forKey: "diffPanelWidth") }
    }
}
