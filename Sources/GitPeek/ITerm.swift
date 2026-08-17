import AppKit
import Foundation

enum ITerm {
    // 通过 Apple Event 取 iTerm2 当前窗口当前 session 的目录。
    // 需要「自动化」权限（首次会弹框）。取不到返回 nil。
    //
    // ⚠️⚠️ 绝对不要改回 fork `/usr/bin/osascript`（2026-08-10 踩过，代价是整机重启）。
    // osascript 是个链了 AppKit 的进程，每次启动都要向 LaunchServices CHECKIN，
    // 消耗一个全局 ASN（Application Serial Number），步长 0x1001 = 4097。
    // 本函数被 ~1-2 次/秒 调用 → 32 位 ASN 低位空间（2^32 / 4097 ≈ 104.8 万次）
    // 约 6.5 天就被耗尽并回绕。一旦回绕成 hi=0x1，loginwindow 的
    // ApplicationManager 会对**每一个** App 的 checkin 都失败，新 App 被 launchd
    // 挂起后再没人 resume，永远停在 T (stopped) 状态 —— 整台机器起不了任何新
    // 应用，且注销重登无效（计数器在开机启动的 launchservicesd 里），只能重启。
    // NSAppleScript 在本进程内发事件，不产生新进程，也就不吃 ASN。
    private static let source = """
    with timeout of 2 seconds
        tell application id "com.googlecode.iterm2"
            if (count of windows) is 0 then return ""
            tell current session of current window
                return variable named "path"
            end tell
        end tell
    end timeout
    """

    static func currentSessionPath() -> String? {
        // iTerm2 没在跑就别发事件 —— 否则 `tell application` 会把它拉起来
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: WindowFollower.itermBundleID).isEmpty else {
            Log.once("iterm-ae", "iTerm2 not running -> skip apple event")
            return nil
        }
        // NSAppleScript 非线程安全 → 一律在主线程执行（主线程本身就是串行的，
        // 不需要额外加锁；加锁反而会和 main.sync 组成死锁）。
        // 调用方是 GitService 的后台串行队列，且全工程没有任何往后台队列的
        // .sync 派发，所以这里 main.sync 不会死锁。最坏阻塞由脚本里的
        // `with timeout of 2 seconds` 兜住。
        if Thread.isMainThread { return runScript() }
        return DispatchQueue.main.sync { runScript() }
    }

    // 仅在主线程调用；script 也只在主线程读写，无数据竞争
    private static var script: NSAppleScript?

    private static func runScript() -> String? {
        if script == nil { script = NSAppleScript(source: source) }
        guard let script else {
            Log.once("iterm-ae", "NSAppleScript(source:) returned nil")
            return nil
        }

        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            logFailure(err)
            return nil
        }
        Log.once("iterm-ae", "apple event ok")

        let trimmed = (result.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // 失败原因写进日志（同一原因只记一次），否则权限被撤销时是静默返回 nil，没法查
    private static func logFailure(_ err: NSDictionary) {
        let code = err[NSAppleScript.errorNumber] as? Int ?? 0
        let msg = err[NSAppleScript.errorMessage] as? String ?? ""
        let why: String
        switch code {
        case -1743: why = "自动化权限被拒 —— 系统设置 › 隐私与安全性 › 自动化 › GitPeek → 勾选 iTerm2"
        case -1712: why = "Apple Event 超时（2s），iTerm2 无响应"
        case -600:  why = "iTerm2 未运行"
        default:    why = msg
        }
        Log.once("iterm-ae", "apple event failed: code=\(code) \(why)")
    }
}
