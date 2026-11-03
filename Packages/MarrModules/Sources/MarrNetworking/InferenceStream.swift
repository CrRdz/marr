import Foundation
import MarrCore

/// Handles arbitrary UTF-8/network boundaries and SSE's multi-line data fields.
struct InferenceSSEDecoder {
    struct Event {
        let name: String?
        let data: String
    }
    private var buffer = Data()
    private var name: String?
    private var dataLines: [String] = []
    private var eventBytes = 0

    mutating func append(_ bytes: Data, endOfStream: Bool = false) throws -> [Event] {
        buffer.append(bytes)
        guard buffer.count <= 16_000_000 else { throw InferenceClientError.invalidResponse }
        var events: [Event] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            try consumeLine(Data(line), into: &events)
        }
        if endOfStream {
            if !buffer.isEmpty {
                try consumeLine(buffer, into: &events)
                buffer.removeAll()
            }
            dispatch(into: &events)
        }
        return events
    }

    private mutating func consumeLine(_ bytes: Data, into events: inout [Event]) throws {
        guard var line = String(data: bytes, encoding: .utf8) else { throw InferenceClientError.invalidResponse }
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { dispatch(into: &events); return }
        if line.hasPrefix(":") { return }
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if fields[0] == "event" { name = value }
        if fields[0] == "data" {
            eventBytes += value.utf8.count
            guard eventBytes <= 16_000_000 else { throw InferenceClientError.invalidResponse }
            dataLines.append(value)
        }
    }

    private mutating func dispatch(into events: inout [Event]) {
        if !dataLines.isEmpty { events.append(Event(name: name, data: dataLines.joined(separator: "\n"))) }
        name = nil
        dataLines.removeAll(keepingCapacity: true)
        eventBytes = 0
    }
}

struct InferenceStreamAccumulator {
    let format: GatewayAPIFormat
    private(set) var text = ""
    private(set) var usage: InferenceTokenUsage?
    private(set) var isComplete = false
    private(set) var receivedTerminator = false
    private(set) var receivedCompletedEvent = false
    private(set) var failure: InferenceClientError?
    private(set) var errorCode: String?
    private(set) var errorParameter: String?
    private(set) var errorMessage: String?
    private var parts: [String: String] = [:]
    private var order: [String] = []
    private var inputTokens = 0

    init(format: GatewayAPIFormat) { self.format = format }

    mutating func consume(_ event: InferenceSSEDecoder.Event) throws {
        if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            if format == .openAIChatCompletions { isComplete = true; receivedTerminator = true }
            return
        }
        guard let decoded = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let object = decoded as? [String: Any] else {
            throw InferenceClientError.invalidResponse
        }
        let type = object["type"] as? String ?? event.name ?? ""
        if type == "error" || object["error"] != nil {
            let error = object["error"] as? [String: Any] ?? object
            captureError(error)
            failure = .apiError(error["message"] as? String ?? "The provider interrupted the response.")
            return
        }
        switch format {
        case .openAIResponses:
            let key = "\(object["output_index"] as? Int ?? 0):\(object["content_index"] as? Int ?? 0)"
            switch type {
            case "response.output_text.delta":
                append(object["delta"] as? String ?? "", key: key)
            case "response.output_text.done":
                replace(object["text"] as? String ?? "", key: key)
            case "response.refusal.delta", "response.refusal.done":
                failure = .refused(object["refusal"] as? String ?? object["delta"] as? String ?? "The provider declined the request.")
            case "response.completed", "response.incomplete", "response.failed":
                receivedTerminator = true
                receivedCompletedEvent = type == "response.completed"
                if let response = object["response"] as? [String: Any] {
                    consumeCompleteResponse(response)
                } else { failure = .invalidResponse }
            default: break
            }
        case .openAIChatCompletions:
            updateUsage(object["usage"] as? [String: Any])
            for choice in object["choices"] as? [[String: Any]] ?? [] where (choice["index"] as? Int ?? 0) == 0 {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                append(Self.contentText(delta["content"]), key: "0")
                if let refusal = delta["refusal"] as? String, !refusal.isEmpty { failure = .refused(refusal) }
                if let reason = choice["finish_reason"] as? String {
                    isComplete = true
                    checkStopReason(reason)
                }
            }
        case .anthropicMessages:
            let key = String(object["index"] as? Int ?? 0)
            switch type {
            case "message_start":
                let message = object["message"] as? [String: Any] ?? [:]
                updateUsage(message["usage"] as? [String: Any])
            case "content_block_start":
                let block = object["content_block"] as? [String: Any] ?? [:]
                if block["type"] as? String == "text" { replace(block["text"] as? String ?? "", key: key) }
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any] ?? [:]
                if delta["type"] as? String == "text_delta" { append(delta["text"] as? String ?? "", key: key) }
            case "message_delta":
                updateUsage(object["usage"] as? [String: Any])
                let delta = object["delta"] as? [String: Any] ?? [:]
                if let reason = delta["stop_reason"] as? String { checkStopReason(reason) }
            case "message_stop": isComplete = true; receivedTerminator = true
            default: break // Thinking/tool blocks are not assistant answer text.
            }
        }
        guard text.utf8.count <= 16_000_000 else { throw InferenceClientError.invalidResponse }
    }

    /// Some compatible gateways ignore stream=true and return a normal JSON body.
    mutating func consumeCompleteResponse(_ object: [String: Any]) {
        updateUsage(object["usage"] as? [String: Any])
        isComplete = true
        if let error = object["error"] as? [String: Any] {
            captureError(error)
            failure = .apiError([error["code"] as? String, error["message"] as? String].compactMap { $0 }.joined(separator: ": "))
            return
        }
        switch format {
        case .openAIResponses:
            let content = (object["output"] as? [[String: Any]] ?? []).flatMap { $0["content"] as? [[String: Any]] ?? [] }
            let answer = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if !answer.isEmpty { text = answer }
            if let refusal = content.first(where: { $0["type"] as? String == "refusal" })?["refusal"] as? String {
                failure = .refused(refusal)
            }
            if object["status"] as? String == "incomplete" { failure = .outputTruncated }
            if let status = object["status"] as? String,
               !["completed", "incomplete", "failed"].contains(status) { failure = .incompleteStream }
            if object["status"] as? String == "failed" || object["error"] is [String: Any] {
                let error = object["error"] as? [String: Any]
                failure = .apiError(error?["message"] as? String ?? "The provider could not finish the response.")
            }
        case .openAIChatCompletions:
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { failure = .invalidResponse; return }
            let message = choice["message"] as? [String: Any] ?? [:]
            text = Self.contentText(message["content"])
            if let refusal = message["refusal"] as? String, !refusal.isEmpty { failure = .refused(refusal) }
            if let reason = choice["finish_reason"] as? String { checkStopReason(reason) }
        case .anthropicMessages:
            text = Self.contentText(object["content"])
            if let reason = object["stop_reason"] as? String { checkStopReason(reason) }
        }
    }

    private mutating func captureError(_ error: [String: Any]) {
        errorCode = error["code"] as? String
        errorParameter = error["param"] as? String
        errorMessage = error["message"] as? String
    }

    private mutating func checkStopReason(_ reason: String) {
        if ["length", "max_tokens"].contains(reason) { failure = .outputTruncated }
        if ["content_filter", "refusal"].contains(reason) { failure = .refused("The provider declined the response.") }
        if ["tool_calls", "function_call", "tool_use"].contains(reason) {
            failure = .apiError("The provider requested a tool that is unavailable in Conversation.")
        }
        if reason == "pause_turn" { failure = .incompleteStream }
    }

    private mutating func append(_ value: String, key: String) {
        guard !value.isEmpty else { return }
        replace((parts[key] ?? "") + value, key: key)
    }

    private mutating func replace(_ value: String, key: String) {
        if parts[key] == nil { order.append(key) }
        parts[key] = value
        text = order.compactMap { parts[$0] }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private mutating func updateUsage(_ value: [String: Any]?) {
        guard let value else { return }
        switch format {
        case .openAIResponses:
            usage = InferenceTokenUsage(inputTokens: value["input_tokens"] as? Int ?? 0, outputTokens: value["output_tokens"] as? Int ?? 0)
        case .openAIChatCompletions:
            usage = InferenceTokenUsage(inputTokens: value["prompt_tokens"] as? Int ?? 0, outputTokens: value["completion_tokens"] as? Int ?? 0)
        case .anthropicMessages:
            if let input = value["input_tokens"] as? Int {
                inputTokens = input + (value["cache_creation_input_tokens"] as? Int ?? 0) + (value["cache_read_input_tokens"] as? Int ?? 0)
            }
            usage = InferenceTokenUsage(inputTokens: inputTokens, outputTokens: value["output_tokens"] as? Int ?? usage?.outputTokens ?? 0)
        }
    }

    private static func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]] ?? [])
            .filter { ["text", "output_text"].contains($0["type"] as? String ?? "") }
            .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }
}

enum InferenceRetryPolicy {
    /// Retry only explicit 429/503 rejection responses, never ambiguous network failures.
    /// Long Retry-After values are left to the user rather than shortened.
    static func delay(response: HTTPURLResponse, retry: Int, now: Date = Date()) -> TimeInterval? {
        guard retry < 2, [429, 503].contains(response.statusCode) else { return nil }
        if let header = response.value(forHTTPHeaderField: "Retry-After") {
            let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds: TimeInterval?
            if let numeric = TimeInterval(value), numeric.isFinite, numeric >= 0 {
                seconds = numeric
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                seconds = formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
            }
            guard let seconds, seconds <= 30 else { return nil }
            return seconds
        }
        return pow(2, Double(retry))
    }
}
