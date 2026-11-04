import Foundation
import Darwin
import MarrCore

enum CodexTransportLimits {
    // thread/read returns a complete transcript, including tool output and
    // attachments. Foundation's 1 MiB default is too small for ordinary history.
    static let maximumMessageSize = 64 * 1024 * 1024
}

/// JSONSerialization produces an immutable object graph here. It is handed to
/// the main actor once, never mutated concurrently or retained by the decoder.
struct CodexDecodedSocketMessage: @unchecked Sendable {
    let object: [String: Any]?
    let invalidText: String?
    let preparedHistory: CodexPreparedHistory?

    static func decode(_ data: Data) -> [Self] {
        data.split(separator: 0x0A).map { line in
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                let thread = (object["result"] as? [String: Any])?["thread"] as? [String: Any]
                let prepared = thread.flatMap { $0["turns"] is [[String: Any]] ? RuntimeHistoryProjection.prepareHistory($0) : nil }
                return Self(object: object, invalidText: nil, preparedHistory: prepared)
            }
            return Self(object: nil, invalidText: String(decoding: line.prefix(16_384), as: UTF8.self), preparedHistory: nil)
        }
    }
}

struct CodexPreparedHistory: Sendable {
    let threadID: String
    let activities: [WorkActivity]
    let answer: String
    let diff: String
    let preparedOffMain: Bool
}

struct WorkActivity: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case status
        case plan
        case command
        case fileChange
        case user
        case message
        case error

        var symbolName: String {
            switch self {
            case .status: "circle.fill"
            case .plan: "list.bullet.clipboard"
            case .command: "terminal"
            case .fileChange: "doc.badge.gearshape"
            case .user: "person.fill"
            case .message: "text.bubble"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    let id: UUID
    let kind: Kind
    var title: String
    var detail: String
    var isComplete: Bool
    var processingSeconds: Int?
    var turnID: String?
    var serverItemID: String?
    var rawJSON: String?
    /// Runtime-provided phase; optional so pre-phase archives remain readable.
    var messagePhase: String?

    var resolvedMessagePhase: String? {
        if let messagePhase { return messagePhase }
        // Only old message records need this compatibility path. Never decode
        // potentially huge tool output to decide the transcript hierarchy.
        guard kind == .message || title == "reasoning" else { return nil }
        let item = CodexProtocolJSON.object(rawJSON)
        return item["type"] as? String == "reasoning" ? "reasoning" : item["phase"] as? String
    }

    var isProcessMessage: Bool {
        ["commentary", "analysis", "reasoning"].contains(resolvedMessagePhase ?? "")
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String = "",
        isComplete: Bool = true,
        processingSeconds: Int? = nil,
        turnID: String? = nil,
        serverItemID: String? = nil,
        rawJSON: String? = nil,
        messagePhase: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isComplete = isComplete
        self.processingSeconds = processingSeconds
        self.turnID = turnID
        self.serverItemID = serverItemID
        self.rawJSON = rawJSON
        self.messagePhase = messagePhase
    }
}

struct CodexSubmissionDraft: Identifiable {
    let id: UUID
    let prompt: String
    let attachments: [ConversationImageAsset]
    let workspaceID: UUID?
    let taskID: UUID?
    var threadID: String?
    let bindings: [ComposerMentionBinding]
    var error: String?

    var hasWriterConflict: Bool { CodexThreadWriterConflict.matches(error ?? "") }
    var recoveryTitle: String { hasWriterConflict ? "Message not sent" : "Message wasn’t confirmed" }
    var recoveryExplanation: String? { hasWriterConflict ? CodexThreadWriterConflict.explanation : error }

    init(id: UUID = UUID(), prompt: String, attachments: [ConversationImageAsset],
         workspaceID: UUID? = nil, taskID: UUID? = nil, threadID: String? = nil,
         bindings: [ComposerMentionBinding] = [], error: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.threadID = threadID
        self.bindings = bindings
        self.error = error
    }
}

enum CodexThreadWriterConflict {
    static func matches(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("already has an active writer")
    }

    static let explanation = "This chat is held by another Codex session. Your message is saved. Continue in the original app, or retry after that session releases the chat."
}

struct CodexApprovalRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case command
        case fileChange

        var title: String {
            switch self {
            case .command: "Allow Codex command?"
            case .fileChange: "Allow Codex file changes?"
            }
        }
    }

    let id: Int
    let kind: Kind
    let reason: String?
    let preview: String?
}

struct CodexModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var reasoningEfforts: [String] = []
    var defaultReasoningEffort: String? = nil
    var description = ""
    var effortDescriptions: [String: String] = [:]

    static func parse(_ rows: [[String: Any]]) -> [Self] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = (row["model"] as? String ?? row["id"] as? String),
                  !id.isEmpty, seen.insert(id).inserted else { return nil }
            let name = (row["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(
                id: id,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                reasoningEfforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                    .compactMap { $0["reasoningEffort"] as? String },
                defaultReasoningEffort: row["defaultReasoningEffort"] as? String,
                description: row["description"] as? String ?? "",
                effortDescriptions: Dictionary(
                    (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { option in
                        guard let key = option["reasoningEffort"] as? String,
                              let text = option["description"] as? String else { return nil }
                        return (key, text)
                    }, uniquingKeysWith: { first, _ in first })
            )
        }
    }
}

enum CodexRuntime {
    static var homeURL: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func launchEnvironment(executables: [URL], inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        var seen = Set<String>()
        let directories = executables.map { $0.deletingLastPathComponent().path }
        let original = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (directories + original + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }

    /// Reserve a fresh loopback port per Marr instance. If another process takes
    /// it before Codex binds, startup fails rather than adopting a foreign server.
    static func availableLocalEndpoint() throws -> URL {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard status == 0 else { throw CocoaError(.fileReadUnknown) }
        return URL(string: "ws://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!
    }

    // Desktop builds can carry protocol/history capabilities that older npm CLIs lack.
    static let automaticPaths = [
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex"
    ]

    static func executableURLs(preferred: URL?) -> [URL] {
        var seen = Set<String>()
        return ([preferred].compactMap { $0 } + automaticPaths.map(URL.init(fileURLWithPath:)))
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

struct CodexFileSearchMatch: Identifiable, Equatable {
    let path: String
    let displayPath: String
    let name: String
    let isDirectory: Bool
    let score: Double
    var id: String { path }

    init?(json: [String: Any]) {
        guard let relative = json["path"] as? String, let root = json["root"] as? String else { return nil }
        path = (relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : URL(fileURLWithPath: root).appendingPathComponent(relative)).standardizedFileURL.path
        displayPath = relative.hasPrefix(root + "/") ? String(relative.dropFirst(root.count + 1)) : relative
        name = json["file_name"] as? String ?? URL(fileURLWithPath: relative).lastPathComponent
        isDirectory = json["match_type"] as? String == "directory"
        score = (json["score"] as? NSNumber)?.doubleValue ?? 0
    }
}

struct CodexThreadGoal: Equatable {
    let threadID: String
    let objective: String
    let status: String
    let tokenBudget: Int?
    let tokensUsed: Int
    let timeUsedSeconds: Int

    init?(json: [String: Any]) {
        guard let threadID = json["threadId"] as? String, let objective = json["objective"] as? String else { return nil }
        self.threadID = threadID
        self.objective = objective
        status = json["status"] as? String ?? "active"
        tokenBudget = json["tokenBudget"] as? Int
        tokensUsed = json["tokensUsed"] as? Int ?? 0
        timeUsedSeconds = json["timeUsedSeconds"] as? Int ?? 0
    }
}
