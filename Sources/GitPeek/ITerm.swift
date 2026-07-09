import Foundation

enum ITerm {
    // 通过 AppleScript 取 iTerm2 当前窗口当前 session 的目录。
    // 需要「自动化」权限（首次会弹框）。取不到返回 nil。
    static func currentSessionPath() -> String? {
        let script = """
        tell application "iTerm2"
            if (count of windows) is 0 then return ""
            tell current session of current window
                return variable named "path"
            end tell
        end tell
        """
        guard let out = Shell.run("/usr/bin/osascript", ["-e", script]) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
