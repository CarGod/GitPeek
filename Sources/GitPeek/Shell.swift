import Foundation

enum Shell {
    // 同步跑一个命令，返回 stdout（trim 尾部换行）。失败返回 nil。
    static func run(_ launchPath: String, _ args: [String], cwd: String? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        // stderr 不消费 → 丢到 null，避免子进程 stderr 塞满 64KiB 缓冲后死锁
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }

    // 找到可用的 git（优先 Homebrew，再系统）
    static let gitPath: String = {
        for c in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return "/usr/bin/git"
    }()

    static func git(_ args: [String], root: String) -> String? {
        // core.quotepath=false：非 ASCII（中文等）路径按 UTF-8 原样输出，不做八进制转义
        run(gitPath, ["-C", root, "-c", "core.quotepath=false"] + args)
    }

    // 专给 `git diff --no-index` 用：它「文件不同」时退出码为 1，不能当失败；
    // 且不裁剪任何空白（diff 里的空白有意义）。
    static func gitDiff(_ args: [String], root: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = ["-C", root, "-c", "core.quotepath=false"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // 同上：不排空会死锁
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus <= 1 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
