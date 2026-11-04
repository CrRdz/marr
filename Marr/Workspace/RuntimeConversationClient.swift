import Foundation
import MarrCore
import PDFKit

/// A separate connection keeps screenshot conversations out of the Work task state.
struct CodexConversationResponseAccumulator {
    private var order: [String] = []
    private var messages: [String: String] = [:]
    private var processMessageIDs: Set<String> = []
    init() {}
    var text: String { order.compactMap { messages[$0] }.filter { !$0.isEmpty }.joined(separator: "\n\n") }

    mutating func receive(method: String, params: [String: Any]) -> Bool {
        if ["item/started", "item/completed"].contains(method),
           let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" {
            let itemID = item["id"] as? String ?? "__answer"
            if let phase = item["phase"] as? String {
                if ["commentary", "analysis", "reasoning"].contains(phase) {
                    processMessageIDs.insert(itemID)
                    // A runtime may supply phase only on completion. Remove a
                    // previously unlabelled fragment rather than duplicate it.
                    let removed = messages.removeValue(forKey: itemID)
                    order.removeAll { $0 == itemID }
                    return removed?.isEmpty == false
                }
                processMessageIDs.remove(itemID)
            }
            if method == "item/started" { return false }
        }
        let id: String
        let value: String
        if method == "item/agentMessage/delta" {
            id = params["itemId"] as? String ?? "__answer"
            value = (messages[id] ?? "") + (params["delta"] as? String ?? "")
        } else if method == "item/completed",
                  let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                  let completedText = item["text"] as? String {
            id = item["id"] as? String ?? "__answer"
            value = completedText
        } else { return false }
        guard !processMessageIDs.contains(id) else { return false }
        if messages[id] == nil { order.append(id) }
        guard messages[id] != value else { return false }
        messages[id] = value
        return true
    }
}

@MainActor
final class CodexConversationClient {
    private let socket: URLSessionWebSocketTask
    private var requestID = 0
    private var notifications: [[String: Any]] = []

    init(endpoint: URL) {
        socket = URLSession.shared.webSocketTask(with: endpoint)
        socket.maximumMessageSize = CodexTransportLimits.maximumMessageSize
    }

    static func input(for request: VisionRequest) throws -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in request.messages {
            input.append(["type": "text", "text": "\n[\(message.role.rawValue)]\n"])
            for content in message.content {
                switch content {
                case .text(let text):
                    input.append(["type": "text", "text": text])
                case .image(let asset):
                    input.append(["type": "image", "url": "data:\(asset.mimeType);base64,\(asset.data.base64EncodedString())"])
                case .file(let asset):
                    let text: String?
                    if asset.mimeType == "application/pdf", let pdf = PDFDocument(data: asset.data) {
                        text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
                    } else {
                        text = String(data: asset.data, encoding: .utf8)
                    }
                    guard let text, !text.isEmpty else {
                        throw UserFacingError("\(asset.fileName): this conversation supports images, text files and text-based PDFs. Export this file to one of those formats first.")
                    }
                    input.append(["type": "text", "text": "Attachment: \(asset.fileName)\n\(text)"])
                }
            }
        }
        return input
    }

    /// These overrides belong only to this ephemeral translation thread. Skills
    /// add unrelated catalog context even when shell and plugin tools are off.
    /// Never use skills/config/write: the user's Work configuration is separate.
    static func translationSkillOverrides(from result: [String: Any]?) -> [String: Any] {
        guard let rows = result?["data"] as? [[String: Any]] else {
            // Older runtimes can lack skills/list; translation should still work.
            return ["skills.max_context_tokens": 1]
        }
        let paths = Set(rows.flatMap { $0["skills"] as? [[String: Any]] ?? [] }
            .compactMap { $0["path"] as? String }
            .filter { $0.hasPrefix("/") })
        return ["skills.config": paths.sorted().map {
            ["path": $0, "enabled": false] as [String: Any]
        }]
    }

    func respond(to request: VisionRequest, model: String, effort: String?, isTranslation: Bool = false, onEvent: VisionResponseHandler? = nil) async throws -> String {
        let input = try Self.input(for: request)
        onEvent?(.requestStarted)
        socket.resume()
        let timeout = Task { [socket] in
            do {
                try await Task.sleep(for: .seconds(180))
                socket.cancel(with: .goingAway, reason: nil)
            } catch {}
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        return try await withTaskCancellationHandler {
            _ = try await rpc("initialize", [
                "clientInfo": ["name": "marr_conversation", "title": "Marr Conversation", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try await send(["method": "initialized", "params": [:]])
            let effective = try await rpc("config/read", ["includeLayers": false])
            let current = effective["config"] as? [String: Any] ?? [:]
            var config: [String: Any] = [
                "features.shell_tool": false, "features.unified_exec": false,
                "features.apply_patch_freeform": false, "features.apps": false,
                "features.plugins": false, "features.multi_agent": false,
                "web_search": "disabled", "project_doc_max_bytes": 0,
                "hooks": [:] as [String: Any]
            ]
            for name in (current["mcp_servers"] as? [String: Any] ?? [:]).keys {
                config["mcp_servers.\(name).enabled"] = false
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Marr-Conversation", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if isTranslation {
                let skills = try? await rpc("skills/list", ["cwds": [directory.path], "forceReload": false])
                try Task.checkCancellation()
                config.merge(Self.translationSkillOverrides(from: skills)) { _, replacement in replacement }
            }
            let result = try await rpc("thread/start", [
                "model": model, "modelProvider": "openai", "cwd": directory.path,
                "ephemeral": true, "approvalPolicy": "never", "sandbox": "read-only",
                "baseInstructions": request.systemPrompt,
                "developerInstructions": "You are a conversational OpenAI assistant. Answer using the supplied conversation and attachments. Do not execute commands, change files, or invoke external tools. The [user] and [assistant] labels delimit conversation history; answer the final user message.",
                "config": config
            ])
            guard let thread = result["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
                throw UserFacingError("Codex did not create the conversation.")
            }
            var turn: [String: Any] = ["threadId": threadID, "model": model, "input": input]
            if let effort { turn["effort"] = effort }
            _ = try await rpc("turn/start", turn)
            var answer = CodexConversationResponseAccumulator()
            while true {
                try Task.checkCancellation()
                let event = try await nextEvent()
                let params = event["params"] as? [String: Any] ?? [:]
                guard params["threadId"] as? String == threadID else { continue }
                let method = event["method"] as? String ?? ""
                if answer.receive(method: method, params: params) { onEvent?(.text(answer.text)) }
                switch method {
                case "thread/tokenUsage/updated":
                    let tokens = params["tokenUsage"] as? [String: Any] ?? [:]
                    if let latest = tokens["last"] as? [String: Any] ?? tokens["total"] as? [String: Any],
                       let input = latest["inputTokens"] as? Int, let output = latest["outputTokens"] as? Int {
                        onEvent?(.usage(InferenceTokenUsage(inputTokens: input, outputTokens: output)))
                    }
                case "turn/completed":
                    let turn = params["turn"] as? [String: Any] ?? [:]
                    guard turn["status"] as? String == "completed" else {
                        let error = turn["error"] as? [String: Any]
                        throw UserFacingError(error?["message"] as? String ?? "Codex conversation did not complete.")
                    }
                    let text = answer.text
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw UserFacingError("Codex returned an empty response.")
                    }
                    return text
                case "error":
                    if params["willRetry"] as? Bool != true {
                        let error = params["error"] as? [String: Any]
                        throw UserFacingError(error?["message"] as? String ?? "Codex request failed.")
                    }
                default: break
                }
            }
        } onCancel: { [socket] in
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func send(_ value: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive() async throws -> [String: Any] {
        try Task.checkCancellation()
        let data: Data
        switch try await socket.receive() {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw UserFacingError("Unknown Codex response.")
        }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UserFacingError("Invalid Codex response.")
        }
        // Conversation never grants tool execution requests.
        if let id = event["id"], event["method"] != nil {
            try await send(["id": id, "error": ["code": -32601, "message": "Tools are disabled in Conversation."]])
        }
        return event
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try await send(["id": id, "method": method, "params": params])
        while true {
            let response = try await receive()
            if response["id"] as? Int == id, response["method"] == nil {
                if let error = response["error"] as? [String: Any] {
                    throw UserFacingError(error["message"] as? String ?? "Codex request failed.")
                }
                return response["result"] as? [String: Any] ?? [:]
            }
            if response["id"] == nil { notifications.append(response) }
        }
    }

    private func nextEvent() async throws -> [String: Any] {
        if !notifications.isEmpty { return notifications.removeFirst() }
        return try await receive()
    }
}
