import Foundation

enum AgentComposerTokenKind: String, Hashable { case slash, file, skill }

struct AgentComposerToken: Hashable {
    let kind: AgentComposerTokenKind
    let query: String
    let replacementRange: NSRange
    /// The original range contents prevent a delayed completion from replacing a newer draft.
    let originalText: String
}

struct AgentComposerEdit: Equatable {
    let text: String
    let caretUTF16: Int
}

enum CodexCommandSupport: String, Equatable { case runtime, interface, terminalOnly }

struct AgentComposerCommand: Identifiable, Equatable {
    let name: String
    let aliases: [String]
    let summary: String
    let support: CodexCommandSupport
    let supportsInlineArguments: Bool
    let upstreamAllowedWhileRunning: Bool
    let allowedWhileRunning: Bool
    let isUpstream: Bool
    let debugOnly: Bool
    var id: String { name }
    var invocation: String { "/" + name }
    var isSupported: Bool { support != .terminalOnly }
}

/// Snapshot of openai/codex main, 2026-10-16. The upstream order is intentional.
/// Support describes this client, not whether the server implements a similarly named RPC.
enum AgentComposerCatalog {
    private static let runtime: Set<String> = ["plan", "goal", "compact", "review", "rename", "status", "pwd", "warnings"]
    private static let interface: Set<String> = ["model", "skills", "apps", "mcp", "plugins", "config", "theme", "new", "clear", "resume", "fork", "archive", "mention", "diff", "copy", "export"]
    private static let inline: Set<String> = ["review", "model", "permissions", "title", "statusline", "rename", "new", "clear", "fork", "plan", "goal", "voice", "ide", "keymap", "mcp", "export", "raw", "cd", "pwd", "usage", "pets", "side", "btw", "resume"]
    private static let upstreamIdle: Set<String> = ["new", "delete", "fork", "worktree", "init", "compact", "recap", "export", "keymap", "tui", "vim", "setup-default-sandbox", "experimental", "memories", "import", "review", "plan", "cd", "clear", "logout", "debug-m-drop", "debug-m-update", "config", "theme", "pets"]
    // This client cannot switch or archive the thread owning an active turn.
    private static let clientIdle: Set<String> = ["resume", "archive"]

    static let commands: [AgentComposerCommand] = {
        let rows: [(String, String)] = [
            ("model", "选择模型与推理强度"), ("presets", "管理可复用提示词"),
            ("daybreak", "切换 Daybreak"), ("ide", "添加 IDE 上下文"),
            ("permissions", "设置操作权限"), ("keymap", "配置终端快捷键"),
            ("vim", "切换 Vim 输入"), ("setup-default-sandbox", "配置增强沙箱"),
            ("experimental", "实验功能"), ("approve", "重试自动审批拒绝的操作"),
            ("memories", "配置记忆"), ("skills", "在设置中查看 Skills"),
            ("import", "导入 Claude Code 配置与历史"), ("hooks", "管理生命周期 Hooks"),
            ("review", "审查工作区变更"), ("rename", "重命名当前任务"),
            ("new", "新建任务"), ("archive", "归档当前任务"),
            ("delete", "永久删除任务"), ("resume", "继续已有任务"),
            ("fork", "分叉当前任务"), ("worktree", "在新工作树继续任务"),
            ("app", "转到 Codex 桌面应用"), ("init", "生成 AGENTS.md"),
            ("compact", "压缩会话上下文"), ("config", "打开设置"),
            ("recap", "生成当前会话摘要"), ("plan", "切换计划模式"),
            ("voice", "语音会话与设置"), ("goal", "设置或管理长期目标"),
            ("agents", "打开代理管理中心"), ("side", "开始临时分支对话"),
            ("btw", "开始临时分支对话"), ("copy", "复制最近回复"),
            ("export", "导出会话为 Markdown"), ("raw", "切换终端原始滚动模式"),
            ("tui", "设置下次启动的终端界面"), ("diff", "查看最近回合的变更"),
            ("mention", "引用工作区文件"), ("status", "查看当前任务状态"),
            ("daemon", "管理后台服务"), ("warnings", "查看诊断信息"),
            ("cd", "切换工作目录"), ("pwd", "显示当前工作目录"),
            ("usage", "查看额度与重置时间"), ("debug-config", "检查配置来源"),
            ("title", "配置终端标题"), ("statusline", "配置终端状态栏"),
            ("theme", "打开外观设置"), ("pets", "选择终端宠物"),
            ("mcp", "查看 MCP 工具与登录"), ("apps", "在设置中查看 Apps"),
            ("plugins", "在设置中查看插件"), ("logout", "退出 Codex 登录"),
            ("quit", "退出终端客户端"), ("exit", "退出终端客户端"),
            ("feedback", "向维护者发送诊断"), ("rollout", "显示会话记录路径"),
            ("ps", "列出后台终端"), ("stop", "停止所有后台终端"),
            ("clear", "清空界面并新建任务"), ("test-approval", "测试审批交互"),
            ("subagents", "切换子代理"), ("debug-m-drop", "记忆调试命令"),
            ("debug-m-update", "记忆调试命令")
        ]
        let aliases = ["pwd": ["cwd"], "pets": ["pet"], "stop": ["clean"]]
        var result = rows.map { name, summary in
            AgentComposerCommand(name: name, aliases: aliases[name] ?? [], summary: summary,
                support: runtime.contains(name) ? .runtime : interface.contains(name) ? .interface : .terminalOnly,
                supportsInlineArguments: inline.contains(name), upstreamAllowedWhileRunning: !upstreamIdle.contains(name),
                allowedWhileRunning: !upstreamIdle.contains(name) && !clientIdle.contains(name),
                isUpstream: true, debugOnly: ["rollout", "test-approval"].contains(name))
        }
        result.append(AgentComposerCommand(name: "help", aliases: [], summary: "查看命令与支持范围", support: .interface,
            supportsInlineArguments: false, upstreamAllowedWhileRunning: true, allowedWhileRunning: true, isUpstream: false, debugOnly: false))
        result.append(AgentComposerCommand(name: "default", aliases: [], summary: "退出 Plan 模式（客户端扩展）", support: .runtime,
            supportsInlineArguments: false, upstreamAllowedWhileRunning: false, allowedWhileRunning: false, isUpstream: false, debugOnly: false))
        return result
    }()

    static func command(named rawName: String) -> AgentComposerCommand? {
        let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        if name.hasPrefix("g"), name.hasSuffix("al") {
            let repeated = name.dropFirst().dropLast(2)
            if !repeated.isEmpty, repeated.allSatisfy({ $0 == "o" }) {
                return commands.first { $0.name == "goal" }
            }
        }
        return commands.first { $0.name == name || $0.aliases.contains(name) }
    }
}

struct AgentComposerCandidate: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let insertion: String
    let kind: AgentComposerTokenKind
    var searchTerms: [String] = []
    var isEnabled: Bool = true
    var disabledReason: String? = nil

    static func skill(name: String, path: String, description: String = "") -> Self {
        Self(id: path, label: name, detail: description.isEmpty ? path : description,
             insertion: "$" + name, kind: .skill, searchTerms: [name, path, description])
    }

    static func file(path: String, displayPath: String? = nil) -> Self {
        let display = displayPath ?? path
        let requiresQuotes = display.contains { $0.isWhitespace || "\"`(),;[]{}@$\\".contains($0) }
        let escaped = display.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Self(id: path, label: display, detail: path,
            insertion: requiresQuotes ? "@\"" + escaped + "\"" : "@" + display,
            kind: .file, searchTerms: [display, path, (display as NSString).lastPathComponent])
    }
}

enum AgentComposerCompletion {
    /// UTF-16 offsets match NSTextView's selection, including CJK and emoji drafts.
    static func token(in text: String, caretUTF16: Int) -> AgentComposerToken? {
        guard caretUTF16 >= 0, caretUTF16 <= text.utf16.count,
              let caretRange = Range(NSRange(location: caretUTF16, length: 0), in: text) else { return nil }
        let caret = caretRange.lowerBound
        guard !isCode(text, before: caret) else { return nil }
        var cursor = text.startIndex
        while cursor < caret {
            let char = text[cursor]
            guard char == "/" || char == "@" || char == "$" else { cursor = text.index(after: cursor); continue }
            let kind: AgentComposerTokenKind = char == "/" ? .slash : char == "@" ? .file : .skill
            let prefix = text[..<cursor]
            let boundary = cursor == text.startIndex || text[text.index(before: cursor)].isWhitespace || "([{：:".contains(text[text.index(before: cursor)])
            guard boundary, !isEscaped(text, at: cursor), !isCode(text, before: cursor),
                  kind != .slash || prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else {
                cursor = text.index(after: cursor); continue
            }
            let contentStart = text.index(after: cursor)
            let quoted = kind == .file && contentStart < text.endIndex && text[contentStart] == "\""
            let queryStart = quoted ? text.index(after: contentStart) : contentStart
            var end = queryStart
            while end < text.endIndex {
                let c = text[end]
                if quoted {
                    if c == "\n" || c == "\r" { break }
                    if c == "\"", !isEscaped(text, at: end) { end = text.index(after: end); break }
                } else if c.isWhitespace || "`\"(),;[]{}<>".contains(c) { break }
                end = text.index(after: end)
            }
            if caret >= contentStart && caret <= end {
                let queryEnd = max(queryStart, caret)
                var query = String(text[queryStart..<queryEnd])
                if quoted, query.hasSuffix("\"") { query.removeLast() }
                if quoted { query = query.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
                // A second sigil means this is an address/expression rather than a completion word.
                if !quoted, query.contains("@") || query.contains("$") { return nil }
                if kind == .skill {
                    let fullQuery = String(text[contentStart..<end])
                    let following = contentStart < text.endIndex ? text[contentStart] : nil
                    if let following, "({!?*#@".contains(following) { return nil }
                    let shellVariables: Set<String> = ["PATH", "HOME", "USER", "SHELL", "PWD", "TMPDIR", "TEMP", "TMP", "LANG", "TERM", "XDG_CONFIG_HOME"]
                    if shellVariables.contains(fullQuery) || fullQuery == "-" || fullQuery == "_" || (!fullQuery.isEmpty && fullQuery.allSatisfy(\.isNumber)) { return nil }
                }
                return AgentComposerToken(kind: kind, query: query, replacementRange: NSRange(cursor..<end, in: text), originalText: String(text[cursor..<end]))
            }
            cursor = max(text.index(after: cursor), end)
        }
        return nil
    }

    static func parse(text: String, caretUTF16: Int) -> AgentComposerToken? { token(in: text, caretUTF16: caretUTF16) }

    static func replacing(token: AgentComposerToken, in text: String, with insertion: String) -> AgentComposerEdit? {
        guard let range = Range(token.replacementRange, in: text), String(text[range]) == token.originalText else { return nil }
        let prefix = String(text[..<range.lowerBound])
        let suffix = String(text[range.upperBound...])
        // Reuse one horizontal separator, but never move the caret into the following line.
        let reuse = suffix.first == " " || suffix.first == "\t"
        let separator = reuse ? "" : " "
        return AgentComposerEdit(text: prefix + insertion + separator + suffix,
            caretUTF16: prefix.utf16.count + insertion.utf16.count + (reuse ? 1 : separator.utf16.count))
    }

    static func replace(text: String, token: AgentComposerToken, with insertion: String) -> AgentComposerEdit? {
        replacing(token: token, in: text, with: insertion)
    }

    static func candidates(for token: AgentComposerToken, commands: [AgentComposerCommand] = AgentComposerCatalog.commands,
                           skills: [AgentComposerCandidate] = [], files: [AgentComposerCandidate] = [],
                           isRunning: Bool = false, limit: Int = 12) -> [AgentComposerCandidate] {
        let source: [AgentComposerCandidate]
        switch token.kind {
        case .file: source = files.filter { $0.kind == .file }
        case .skill: source = skills.filter { $0.kind == .skill }
        case .slash:
            source = commands.filter { !$0.debugOnly }.map { command in
                let reason = command.support == .terminalOnly ? "此客户端尚未接入" : isRunning && !command.allowedWhileRunning ? "等待当前回合结束后使用" : nil
                return AgentComposerCandidate(id: command.name, label: command.invocation, detail: command.summary,
                    insertion: command.invocation, kind: .slash, searchTerms: [command.name] + command.aliases,
                    isEnabled: reason == nil, disabledReason: reason)
            }
        }
        return rankedCandidates(query: token.query, candidates: source, limit: limit)
    }

    static func rankedCandidates(query: String, candidates: [AgentComposerCandidate], limit: Int = 12) -> [AgentComposerCandidate] {
        guard limit > 0 else { return [] }
        let query = folded(query)
        var seen = Set<String>()
        return candidates.enumerated().compactMap { index, candidate -> (Int, Int, AgentComposerCandidate)? in
            guard seen.insert(candidate.kind.rawValue + ":" + candidate.id).inserted else { return nil }
            let terms = [candidate.label.trimmingCharacters(in: CharacterSet(charactersIn: "/@$"))] + candidate.searchTerms
            guard let score = terms.compactMap({ matchScore(query: query, value: folded($0)) }).min() else { return nil }
            return (score, index, candidate)
        }.sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            // Preserve supplied catalogue order on an empty query; otherwise stable lexical ties.
            if query.isEmpty { return left.1 < right.1 }
            let lhs = folded(left.2.label), rhs = folded(right.2.label)
            if lhs != rhs { return lhs < rhs }
            if left.2.id != right.2.id { return left.2.id < right.2.id }
            return left.1 < right.1
        }.prefix(limit).map { $0.2 }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func matchScore(query: String, value: String) -> Int? {
        if query.isEmpty || value == query { return 0 }
        if value.hasPrefix(query) { return 1 }
        if value.split(whereSeparator: { "/_.- :".contains($0) }).contains(where: { $0.hasPrefix(query) }) { return 2 }
        if value.contains(query) { return 3 }
        var remaining = query[...]
        for char in value where !remaining.isEmpty { if char == remaining.first { remaining.removeFirst() } }
        return remaining.isEmpty ? 4 : nil
    }

    private static func isEscaped(_ text: String, at index: String.Index) -> Bool {
        var cursor = index, count = 0
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            guard text[cursor] == "\\" else { break }
            count += 1
        }
        return count % 2 == 1
    }

    /// Markdown code spans/fences suppress popups without suppressing prose after their closure.
    private static func isCode(_ text: String, before target: String.Index) -> Bool {
        var cursor = text.startIndex
        var delimiter: Character? = nil
        var delimiterCount = 0
        var fenced = false
        var lineOnlyWhitespace = true
        while cursor < target {
            let char = text[cursor]
            if (char == "`" || (char == "~" && lineOnlyWhitespace)), !isEscaped(text, at: cursor) {
                var end = cursor
                while end < target && text[end] == char { end = text.index(after: end) }
                let count = text.distance(from: cursor, to: end)
                if let open = delimiter {
                    if char == open && ((fenced && lineOnlyWhitespace && count >= delimiterCount) || (!fenced && count == delimiterCount)) {
                        delimiter = nil; delimiterCount = 0; fenced = false
                    }
                } else if char == "`" || count >= 3 {
                    delimiter = char; delimiterCount = count; fenced = lineOnlyWhitespace && count >= 3
                }
                lineOnlyWhitespace = false
                cursor = end
                continue
            }
            if char == "\n" { lineOnlyWhitespace = true }
            else if char != " " && char != "\t" { lineOnlyWhitespace = false }
            cursor = text.index(after: cursor)
        }
        return delimiter != nil
    }
}
