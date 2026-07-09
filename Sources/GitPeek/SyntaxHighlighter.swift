import SwiftUI

// 语法配色（暗底）
enum SyntaxColor {
    static let deflt   = Color(white: 0.86)
    static let comment = Color(red: 0.46, green: 0.55, blue: 0.46)   // 灰绿
    static let string  = Color(red: 0.83, green: 0.62, blue: 0.44)   // 橙棕
    static let number  = Color(red: 0.62, green: 0.78, blue: 0.96)   // 浅蓝
    static let keyword = Color(red: 0.82, green: 0.58, blue: 0.88)   // 紫
    static let type    = Color(red: 0.42, green: 0.80, blue: 0.88)   // 青
}

// 轻量、语言无关的语法高亮器：逐行上色，块注释状态跨行传递。
enum Syntax {
    struct Config { let lineTokens: [String]; let block: Bool }

    static func config(for path: String) -> Config {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml", "r", "pl",
             "conf", "ini", "cfg", "dockerfile", "makefile", "mk", "gemfile":
            return Config(lineTokens: ["#"], block: false)
        case "sql", "lua", "hs", "elm", "ada":
            return Config(lineTokens: ["--"], block: false)
        case "lisp", "clj", "cljs", "el", "scm":
            return Config(lineTokens: [";"], block: false)
        case "css", "scss", "less":
            return Config(lineTokens: ["//"], block: true)
        default:
            // c 系（c/cpp/h/java/js/ts/go/swift/kt/rs/cs/php/scala…）及未知
            return Config(lineTokens: ["//"], block: true)
        }
    }

    static let keywords: Set<String> = [
        "func","def","function","fn","class","struct","enum","interface","protocol",
        "extension","trait","impl","return","if","else","elif","elseif","for","while",
        "do","switch","case","default","break","continue","let","var","const","val",
        "public","private","protected","internal","static","final","abstract","sealed",
        "override","open","fileprivate","mutating","nonmutating","lazy","weak","unowned",
        "void","int","long","short","float","double","bool","boolean","char","byte","string",
        "new","delete","try","catch","throw","throws","finally","rethrows","guard","defer",
        "import","from","export","package","namespace","using","include","require","module",
        "async","await","yield","lambda","self","this","super","null","nil","none","undefined",
        "true","false","and","or","not","in","is","as","typeof","instanceof","typealias",
        "init","deinit","get","set","where","associatedtype","operator","subscript",
        "type","interface","go","chan","defer","map","range","select","goto","with","pass",
        "raise","except","lambda","global","nonlocal","assert","del","print","echo","fn"
    ]

    static func highlight(_ text: String, cfg: Config, inBlock: inout Bool) -> AttributedString {
        // 超长行不做逐 token 高亮：AttributedString 拼接是 O(n)，逐段拼会退化成 O(n²)。单色返回。
        if text.count > 2000 {
            var a = AttributedString(text)
            a.foregroundColor = inBlock ? SyntaxColor.comment : SyntaxColor.deflt
            return a
        }

        var out = AttributedString()
        let chars = Array(text)
        let n = chars.count
        var i = 0
        var pending = ""   // 累积连续的默认色内容（标识符/标点/空格），一次性 emit，避免逐字符拼接
        var guardCount = 0 // 防御：任何意外的不前进都不至于把程序卡死

        func flushPending() {
            guard !pending.isEmpty else { return }
            var a = AttributedString(pending)
            a.foregroundColor = SyntaxColor.deflt
            out += a
            pending = ""
        }
        func emit(_ str: String, _ color: Color) {
            flushPending()
            var a = AttributedString(str)
            a.foregroundColor = color
            out += a
        }

        while i < n {
            guardCount += 1
            if guardCount > n * 4 + 100 { flushPending(); break }
            // 块注释续行 / 进行中
            if inBlock {
                var j = i
                while j < n {
                    if chars[j] == "*" && j + 1 < n && chars[j + 1] == "/" { j += 2; inBlock = false; break }
                    j += 1
                }
                emit(String(chars[i..<j]), SyntaxColor.comment)
                i = j
                continue
            }

            let c = chars[i]

            // 块注释开始
            if cfg.block, c == "/", i + 1 < n, chars[i + 1] == "*" {
                inBlock = true
                continue   // 交给上面的块分支从 i 开始吞
            }

            // 行注释
            if let tok = lineCommentAt(chars, i, cfg.lineTokens) {
                _ = tok
                emit(String(chars[i..<n]), SyntaxColor.comment)
                break
            }

            // 字符串
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                var j = i + 1
                while j < n {
                    if chars[j] == "\\" && j + 1 < n { j += 2; continue }
                    if chars[j] == quote { j += 1; break }
                    j += 1
                }
                emit(String(chars[i..<j]), SyntaxColor.string)
                i = j
                continue
            }

            // 数字：仅 ASCII 0-9 起头。CJK 数字（如「参」=叁、「一二三」）也满足 isNumber，
            // 但非 hex → 内层 while 不前进、j 停在 i → 死循环；限 ASCII 并让 j 从 i+1 起步双保险。
            if c.isNumber && c.isASCII {
                var j = i + 1
                while j < n, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x"
                            || chars[j] == "X" || chars[j] == "_" || chars[j] == "e" {
                    j += 1
                }
                emit(String(chars[i..<j]), SyntaxColor.number)
                i = j
                continue
            }

            // 标识符 / 关键字
            if c.isLetter || c == "_" {
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                if keywords.contains(word) {
                    emit(word, SyntaxColor.keyword)
                } else if let f = word.first, f.isUppercase {
                    emit(word, SyntaxColor.type)
                } else {
                    pending += word            // 默认色 → 累积
                }
                i = j
                continue
            }

            // 其他单字符（标点/空格）→ 累积
            pending.append(c)
            i += 1
        }
        flushPending()
        return out
    }

    private static func lineCommentAt(_ chars: [Character], _ i: Int, _ tokens: [String]) -> String? {
        for tok in tokens {
            let t = Array(tok)
            if i + t.count <= chars.count, Array(chars[i..<i + t.count]) == t { return tok }
        }
        return nil
    }
}
