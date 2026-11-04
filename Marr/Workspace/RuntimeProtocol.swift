import Foundation
import CoreFoundation

struct CodexAccount: Equatable {
    let type: String
    let email: String?
    let planType: String?

    init?(json: [String: Any]) {
        guard let type = json["type"] as? String else { return nil }
        self.type = type
        email = json["email"] as? String
        planType = json["planType"] as? String
    }
}

struct CodexAccountLogin: Identifiable, Equatable {
    let id: String
    let type: String
    let url: URL?
    let userCode: String?

    init?(json: [String: Any]) {
        guard let id = json["loginId"] as? String, let type = json["type"] as? String else { return nil }
        self.id = id
        self.type = type
        let candidate = (json["authUrl"] as? String ?? json["verificationUrl"] as? String).flatMap(URL.init(string:))
        url = candidate.flatMap {
            let scheme = $0.scheme?.lowercased()
            let isLoopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains($0.host?.lowercased() ?? "")
            return $0.host != nil && (scheme == "https" || (scheme == "http" && isLoopback)) ? $0 : nil
        }
        userCode = json["userCode"] as? String
    }
}

/// Per-thread usage from thread/tokenUsage/updated. Account quota is deliberately separate.
struct CodexThreadTokenUsage: Equatable {
    let model: String
    let lastInputTokens: Int
    let lastOutputTokens: Int
    let lastCachedInputTokens: Int
    let lastTotalTokens: Int
    let contextWindow: Int?
    var lastRequestFraction: Double? {
        contextWindow.map { min(1, Double(lastTotalTokens) / Double($0)) }
    }

    init?(json: [String: Any], model: String) {
        func count(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue < Double(Int.max), number.doubleValue.rounded(.down) == number.doubleValue
            else { return nil }
            return number.intValue
        }
        guard let last = json["last"] as? [String: Any],
              let input = count(last["inputTokens"]), let output = count(last["outputTokens"]),
              let cached = count(last["cachedInputTokens"]), let total = count(last["totalTokens"])
        else { return nil }
        self.model = model
        lastInputTokens = input
        lastOutputTokens = output
        lastCachedInputTokens = cached
        lastTotalTokens = total
        contextWindow = count(json["modelContextWindow"]).flatMap { $0 > 0 ? $0 : nil }
    }
}

struct CodexRateLimitWindow: Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    init?(json: [String: Any]) {
        guard let used = json["usedPercent"] as? NSNumber,
              CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite else { return nil }
        usedPercent = used.doubleValue
        windowDurationMins = json["windowDurationMins"] as? Int
        resetsAt = (json["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}

struct CodexRateLimitBucket: Identifiable, Equatable {
    let id: String
    let name: String
    let planType: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let creditsBalance: String?
    let creditsUnlimited: Bool?
    let hasCredits: Bool?

    init(id: String, json: [String: Any]) {
        self.id = id
        name = json["limitName"] as? String ?? json["limitId"] as? String ?? id
        planType = json["planType"] as? String
        primary = (json["primary"] as? [String: Any]).flatMap(CodexRateLimitWindow.init(json:))
        secondary = (json["secondary"] as? [String: Any]).flatMap(CodexRateLimitWindow.init(json:))
        let credits = json["credits"] as? [String: Any]
        creditsBalance = credits?["balance"] as? String
        creditsUnlimited = credits?["unlimited"] as? Bool
        hasCredits = credits?["hasCredits"] as? Bool
    }
}

struct CodexAccountUsage: Equatable {
    let lifetimeTokens: Int?
    let peakDailyTokens: Int?
    let currentStreakDays: Int?
    let longestStreakDays: Int?
    let longestRunningTurnSec: Int?
    let dailyUsageBuckets: [CodexDailyUsageBucket]?

    init?(json: [String: Any]) {
        guard let summary = json["summary"] as? [String: Any] else { return nil }
        lifetimeTokens = summary["lifetimeTokens"] as? Int
        peakDailyTokens = summary["peakDailyTokens"] as? Int
        currentStreakDays = summary["currentStreakDays"] as? Int
        longestStreakDays = summary["longestStreakDays"] as? Int
        longestRunningTurnSec = summary["longestRunningTurnSec"] as? Int
        dailyUsageBuckets = (json["dailyUsageBuckets"] as? [[String: Any]])?.compactMap(CodexDailyUsageBucket.init(json:))
    }
}

struct CodexDailyUsageBucket: Identifiable, Equatable {
    let startDate: String
    let tokens: Int
    var id: String { startDate }

    init?(json: [String: Any]) {
        guard let startDate = json["startDate"] as? String, let tokens = json["tokens"] as? Int else { return nil }
        self.startDate = startDate
        self.tokens = tokens
    }
}

struct CodexConfigurationLayer: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String?
    let version: String
    let disabledReason: String?

    init?(json: [String: Any]) {
        guard let source = json["name"] as? [String: Any], let version = json["version"] as? String else { return nil }
        name = Self.label(source)
        path = source["file"] as? String ?? source["dotCodexFolder"] as? String
        self.version = version
        disabledReason = json["disabledReason"] as? String
        id = name + ":" + (path ?? source["id"] as? String ?? "")
    }

    static func label(_ source: [String: Any]) -> String {
        let type = source["type"] as? String ?? "unknown"
        if let profile = source["profile"] as? String { return "\(type) · \(profile)" }
        if let name = source["name"] as? String { return "\(type) · \(name)" }
        return type
    }
}

/// Display only the supported settings. Never surface arbitrary config values such as credentials.
struct CodexConfiguration: Equatable {
    let webSearch: String?
    let modelVerbosity: String?
    let modelReasoningSummary: String?
    let analyticsEnabled: Bool?
    let model: String?
    let modelProvider: String?
    let approvalPolicy: String?
    let sandboxMode: String?
    let userFilePath: String?
    let userVersion: String?
    let layers: [CodexConfigurationLayer]
    let origins: [String: String]

    init?(json: [String: Any]) {
        guard let config = json["config"] as? [String: Any] else { return nil }
        webSearch = config["web_search"] as? String
        modelVerbosity = config["model_verbosity"] as? String
        modelReasoningSummary = config["model_reasoning_summary"] as? String
        analyticsEnabled = (config["analytics"] as? [String: Any])?["enabled"] as? Bool
        model = config["model"] as? String
        modelProvider = config["model_provider"] as? String
        approvalPolicy = config["approval_policy"] as? String ?? (config["approval_policy"] == nil ? nil : "Granular policy")
        sandboxMode = config["sandbox_mode"] as? String
        let rows = json["layers"] as? [[String: Any]] ?? []
        layers = rows.compactMap(CodexConfigurationLayer.init(json:))
        let userLayer = rows.first {
            guard let source = $0["name"] as? [String: Any] else { return false }
            return source["type"] as? String == "user" && (source["profile"] == nil || source["profile"] is NSNull)
        }
        userFilePath = (userLayer?["name"] as? [String: Any])?["file"] as? String
        userVersion = userLayer?["version"] as? String
        origins = (json["origins"] as? [String: [String: Any]] ?? [:]).compactMapValues { value in
            guard let source = value["name"] as? [String: Any] else { return nil }
            return CodexConfigurationLayer.label(source)
        }
    }
}

struct CodexConfigurationRequirements: Equatable {
    let allowedWebSearchModes: [String]?
    let allowedLoginMethods: [String]?
    let summary: String

    init(json: [String: Any]) {
        allowedWebSearchModes = json["allowedWebSearchModes"] as? [String]
        allowedLoginMethods = json["allowedLoginMethods"] as? [String]
        func label(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized }
        var rows: [String] = []
        for (key, title) in [("allowedSandboxModes", "Allowed sandboxes"), ("allowedApprovalPolicies", "Allowed approvals"),
            ("allowedApprovalsReviewers", "Approval reviewers"), ("allowedWebSearchModes", "Web search modes"), ("allowedLoginMethods", "Sign-in methods")] {
            if let values = json[key] as? [String] { rows.append("\(title): \(values.isEmpty ? "None" : values.map(label).joined(separator: ", "))") }
        }
        for (key, title) in [("allowLoginShell", "Login shell"), ("allowBrowserAndComputerUse", "Browser and computer access"),
            ("allowAppshots", "App screenshots"), ("allowRemoteControl", "Remote control")] {
            if let allowed = json[key] as? Bool { rows.append("\(title): \(allowed ? "Allowed" : "Disabled")") }
        }
        if let flags = json["featureRequirements"] as? [String: Bool], !flags.isEmpty {
            rows.append("Feature policies: " + flags.keys.sorted().map { "\(label($0)) \(flags[$0] == true ? "enabled" : "disabled")" }.joined(separator: ", "))
        }
        if let profiles = json["allowedPermissionProfiles"] as? [String: Bool], !profiles.isEmpty {
            rows.append("Permission profiles: " + profiles.keys.sorted().map { "\($0) \(profiles[$0] == true ? "allowed" : "disabled")" }.joined(separator: ", "))
        }
        summary = rows.isEmpty ? (json.isEmpty ? "No managed restrictions were returned." : "Managed requirements are configured; the runtime enforces them.") : rows.joined(separator: "\n")
    }
}

struct CodexExperimentalFeature: Identifiable, Equatable {
    let name: String
    let displayName: String
    let stage: String
    let description: String
    let enabled: Bool
    let defaultEnabled: Bool
    var id: String { name }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, let stage = json["stage"] as? String,
              let enabled = json["enabled"] as? Bool, let defaultEnabled = json["defaultEnabled"] as? Bool else { return nil }
        self.name = name
        displayName = json["displayName"] as? String ?? name.replacingOccurrences(of: "_", with: " ").capitalized
        self.stage = stage
        description = json["description"] as? String ?? ""
        self.enabled = enabled
        self.defaultEnabled = defaultEnabled
    }
}

/// JSON-RPC permits both string and integer identifiers. Preserve the wire type.
enum CodexRequestID: Hashable, Codable {
    case integer(Int)
    case string(String)

    init?(_ value: Any) {
        if let value = value as? String { self = .string(value) }
        else if let value = value as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID(),
                let integer = Int(value.stringValue) { self = .integer(integer) }
        else { return nil }
    }

    var rawValue: Any {
        switch self { case .integer(let value): value; case .string(let value): value }
    }
}

enum CodexInteractionAction: String { case accept, decline, cancel }

struct CodexApprovalDecision: Identifiable {
    let rawValue: Any
    let title: String
    let detail: String
    var id: String { CodexProtocolJSON.pretty(rawValue) }

    init?(_ value: Any) {
        rawValue = value
        if let name = value as? String {
            switch name {
            case "accept": title = "Allow once"; detail = "Allow this operation."
            case "acceptForSession": title = "Allow for this session"; detail = "Allow this operation and matching requests for the current session."
            default: return nil
            }
        } else if let object = value as? [String: Any], object.count == 1 {
            if let rule = object["acceptWithExecpolicyAmendment"] as? [String: Any],
               let command = rule["execpolicy_amendment"] as? [String], !command.isEmpty {
                title = "Allow and save command rule"
                detail = "Allow future matching commands using this rule:\n" + CodexProtocolJSON.pretty(command)
            } else if let rule = object["applyNetworkPolicyAmendment"] as? [String: Any],
                      let amendment = rule["network_policy_amendment"] as? [String: Any],
                      let host = amendment["host"] as? String, !host.isEmpty,
                      let action = amendment["action"] as? String, ["allow", "deny"].contains(action) {
                title = action == "allow" ? "Save network allow rule" : "Save network deny rule"
                detail = "Apply a network rule for future requests:\n" + CodexProtocolJSON.pretty(amendment)
            } else { return nil }
        } else { return nil }
    }
}

struct CodexQuestionOption: Identifiable {
    let label: String
    let description: String
    var id: String { label }
}

struct CodexQuestion: Identifiable {
    let id: String
    let header: String
    let question: String
    let isSecret: Bool
    let isOther: Bool
    let options: [CodexQuestionOption]
}

struct CodexFormField: Identifiable {
    let name: String
    let title: String
    let type: String
    let required: Bool
    let options: [String]
    let description: String
    let defaultValue: String
    var optionTitles: [String: String] = [:]
    var id: String { name }
}

struct CodexProtocolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CodexInteractionRequest: Identifiable {
    let id: CodexRequestID
    let method: String
    let params: [String: Any]

    var threadID: String? { params["threadId"] as? String }
    var turnID: String? { params["turnId"] as? String }
    var isQuestion: Bool { ["item/tool/requestUserInput", "tool/requestUserInput"].contains(method) }
    var isOperationApproval: Bool { ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) }
    var approvalDecisions: [CodexApprovalDecision] {
        guard isOperationApproval else { return [] }
        if method == "item/commandExecution/requestApproval", let choices = params["availableDecisions"] as? [Any] {
            return choices.compactMap(CodexApprovalDecision.init)
        }
        var choices: [Any] = ["accept", "acceptForSession"]
        if method == "item/commandExecution/requestApproval" {
            if let command = params["proposedExecpolicyAmendment"] as? [String] {
                choices.append(["acceptWithExecpolicyAmendment": ["execpolicy_amendment": command]])
            }
            for amendment in params["proposedNetworkPolicyAmendments"] as? [[String: Any]] ?? [] {
                choices.append(["applyNetworkPolicyAmendment": ["network_policy_amendment": amendment]])
            }
        }
        return choices.compactMap(CodexApprovalDecision.init)
    }

    func approvalResponse(decision: CodexApprovalDecision) throws -> [String: Any] {
        guard approvalDecisions.contains(where: { CodexProtocolJSON.equal($0.rawValue, decision.rawValue) }) else {
            throw CodexProtocolError(message: "This approval decision was not offered by the server.")
        }
        return ["decision": decision.rawValue]
    }
    var title: String {
        switch method {
        case "item/commandExecution/requestApproval": "Allow command?"
        case "item/fileChange/requestApproval": "Allow file changes?"
        case "item/permissions/requestApproval": "Allow requested access?"
        case "item/tool/requestUserInput", "tool/requestUserInput": "Your input is needed"
        case "mcpServer/elicitation/request": "\(params["serverName"] as? String ?? "Plugin") needs your input"
        default: "Unsupported interaction"
        }
    }
    var message: String { params["message"] as? String ?? params["reason"] as? String ?? "" }
    var preview: String {
        if let permissions = params["permissions"] { return CodexProtocolJSON.pretty(permissions) }
        var lines = [params["command"] as? String, params["grantRoot"] as? String].compactMap { $0 }
        for key in ["networkApprovalContext", "additionalPermissions", "changes"] {
            if let value = params[key] { lines.append(CodexProtocolJSON.pretty(value)) }
        }
        return lines.joined(separator: "\n")
    }
    var url: URL? {
        guard let raw = params["url"] as? String, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    var questions: [CodexQuestion] {
        (params["questions"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, let question = row["question"] as? String else { return nil }
            return CodexQuestion(id: id, header: row["header"] as? String ?? "", question: question,
                isSecret: row["isSecret"] as? Bool ?? false, isOther: row["isOther"] as? Bool ?? true,
                options: (row["options"] as? [[String: Any]] ?? []).compactMap { option in
                    guard let label = option["label"] as? String else { return nil }
                    return CodexQuestionOption(label: label, description: option["description"] as? String ?? "")
                })
        }
    }
    var formFields: [CodexFormField] {
        let schema = params["requestedSchema"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        return (schema["properties"] as? [String: [String: Any]] ?? [:]).sorted { $0.key < $1.key }.map { name, field in
            let defaultValue = field["default"].map { value -> String in
                if let text = value as? String { return text }
                return CodexProtocolJSON.pretty(value)
            } ?? ""
            let choices = CodexFormValidation.options(field["type"] as? String == "array"
                ? field["items"] as? [String: Any] ?? [:] : field)
            return CodexFormField(name: name, title: field["title"] as? String ?? name,
                type: field["type"] as? String ?? "string", required: required.contains(name),
                options: choices.map(\.value), description: field["description"] as? String ?? "",
                defaultValue: defaultValue, optionTitles: choices.reduce(into: [:]) { $0[$1.value] = $1.title })
        }
    }
    var supportsAcceptance: Bool {
        switch method {
        case "item/commandExecution/requestApproval":
            guard let choices = params["availableDecisions"] as? [Any] else { return true }
            return choices.contains { $0 as? String == "accept" }
        case "item/fileChange/requestApproval", "item/permissions/requestApproval": return true
        case "item/tool/requestUserInput", "tool/requestUserInput": return !questions.isEmpty
        case "mcpServer/elicitation/request":
            if params["mode"] as? String == "url" { return url != nil }
            guard ["form", "openai/form", "openaiForm"].contains(params["mode"] as? String ?? ""),
                  let schema = params["requestedSchema"] as? [String: Any] else { return false }
            return CodexFormValidation.supports(schema)
        default: return false
        }
    }

    func response(action: CodexInteractionAction, answers: [String: [String]] = [:],
                  formValues: [String: String] = [:]) throws -> [String: Any] {
        if action == .accept, !supportsAcceptance {
            throw CodexProtocolError(message: "This interaction cannot be accepted by this client. Use Decline or Cancel.")
        }
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return ["decision": action.rawValue]
        case "item/permissions/requestApproval":
            let requested = params["permissions"] as? [String: Any] ?? [:]
            let granted = requested.filter { ["network", "fileSystem"].contains($0.key) && !($0.value is NSNull) }
            return ["permissions": action == .accept ? granted : [:], "scope": "turn"]
        case "item/tool/requestUserInput", "tool/requestUserInput":
            var result: [String: Any] = [:]
            if action == .accept {
                for question in questions {
                    let values = (answers[question.id] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    guard !values.isEmpty else { throw CodexProtocolError(message: "Answer \(question.header.isEmpty ? question.question : question.header) before continuing.") }
                    if !question.isOther, !question.options.isEmpty,
                       !values.allSatisfy({ value in question.options.contains { $0.label == value } }) {
                        throw CodexProtocolError(message: "Choose one of the available answers for \(question.header).")
                    }
                    result[question.id] = ["answers": values]
                }
            }
            return ["answers": result]
        case "mcpServer/elicitation/request":
            var content: Any = NSNull()
            if action == .accept, params["mode"] as? String != "url" {
                let schema = params["requestedSchema"] as? [String: Any] ?? [:]
                var values: [String: Any] = [:]
                for field in formFields {
                    let raw = formValues[field.name] ?? field.defaultValue
                    if raw.isEmpty, !field.required { continue }
                    if field.type == "string" { values[field.name] = raw }
                    else {
                        guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) else {
                            throw CodexProtocolError(message: "\(field.title) must be a valid \(field.type) value.")
                        }
                        values[field.name] = value
                    }
                }
                try CodexFormValidation.validate(values, schema: schema, path: "Form")
                content = values
            }
            return ["action": action.rawValue, "content": content, "_meta": NSNull()]
        case "item/tool/call":
            return ["success": false, "contentItems": [["type": "inputText", "text": "This client does not provide the requested desktop tool. Continue with an available runtime tool or open this task in the supporting client."]]]
        default: throw CodexProtocolError(message: "Unsupported server request: \(method)")
        }
    }
}

/// Forms are validated before returning an accept response; unimplemented schema
/// constraints are deliberately reported rather than silently dropped.
enum CodexFormValidation {
    private static let supportedKeys: Set<String> = ["$schema", "type", "title", "description", "default", "properties", "required", "additionalProperties", "enum", "enumNames", "oneOf", "anyOf", "const", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength", "pattern", "format", "items", "minItems", "maxItems", "uniqueItems"]

    /// MCP titled choices use const/title branches, not arbitrary JSON Schema unions.
    private static func titledOptions(_ schema: [String: Any]) -> [(value: String, title: String)]? {
        let keys = ["oneOf", "anyOf"].filter { schema[$0] != nil }
        guard keys.count == 1, let rows = schema[keys[0]] as? [[String: Any]], !rows.isEmpty else { return nil }
        var result: [(value: String, title: String)] = []
        for row in rows {
            guard Set(row.keys).isSubset(of: ["const", "title"]), let value = row["const"] as? String,
                  let title = row["title"] as? String, !result.contains(where: { $0.value == value }) else { return nil }
            result.append((value, title))
        }
        return result
    }

    static func options(_ schema: [String: Any]) -> [(value: String, title: String)] {
        if let choices = titledOptions(schema) { return choices }
        guard let choices = schema["enum"] as? [String] else { return [] }
        let titles = schema["enumNames"] as? [String] ?? []
        return choices.enumerated().map { index, value in (value, index < titles.count ? titles[index] : value) }
    }

    static func supports(_ schema: [String: Any]) -> Bool {
        let titled = titledOptions(schema)
        if schema["oneOf"] != nil || schema["anyOf"] != nil {
            guard titled != nil, schema["type"] == nil || schema["type"] as? String == "string" else { return false }
        }
        guard Set(schema.keys).isSubset(of: supportedKeys),
              let type = schema["type"] as? String ?? (titled != nil ? "string" : nil),
              ["object", "array", "string", "number", "integer", "boolean"].contains(type) else { return false }
        if let format = schema["format"] as? String, !["email", "uri", "date", "date-time"].contains(format) { return false }
        if let props = schema["properties"] as? [String: [String: Any]], !props.values.allSatisfy(supports) { return false }
        if let items = schema["items"] as? [String: Any], !supports(items) { return false }
        if schema["additionalProperties"] is [String: Any] { return false }
        return true
    }

    static func validate(_ value: Any, schema: [String: Any], path: String) throws {
        func fail(_ text: String) throws { throw CodexProtocolError(message: "\(path): \(text)") }
        guard supports(schema) else { try fail("this form uses unsupported validation rules."); return }
        if let choices = titledOptions(schema), !choices.contains(where: { $0.value == value as? String }) { try fail("choose an allowed value.") }
        if let choices = schema["enum"] as? [Any], !choices.contains(where: { CodexProtocolJSON.equal($0, value) }) { try fail("choose an allowed value.") }
        if let expected = schema["const"], !CodexProtocolJSON.equal(expected, value) { try fail("value does not match the required value.") }
        switch schema["type"] as? String ?? (titledOptions(schema) != nil ? "string" : nil) {
        case "object":
            guard let object = value as? [String: Any] else { try fail("enter an object."); return }
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { try fail("\(key) is required.") }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for (name, child) in object {
                if let rule = properties[name] { try validate(child, schema: rule, path: "\(path).\(name)") }
                else if schema["additionalProperties"] as? Bool == false { try fail("unexpected field \(name).") }
            }
        case "array":
            guard let array = value as? [Any] else { try fail("enter a JSON array."); return }
            if let min = schema["minItems"] as? Int, array.count < min { try fail("at least \(min) items are required.") }
            if let max = schema["maxItems"] as? Int, array.count > max { try fail("at most \(max) items are allowed.") }
            if schema["uniqueItems"] as? Bool == true {
                for i in array.indices where array[..<i].contains(where: { CodexProtocolJSON.equal($0, array[i]) }) { try fail("items must be unique.") }
            }
            if let items = schema["items"] as? [String: Any] {
                for (i, child) in array.enumerated() { try validate(child, schema: items, path: "\(path)[\(i)]") }
            }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { try fail("choose true or false."); return }
        case "number", "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { try fail("enter a number."); return }
            let n = number.doubleValue
            if schema["type"] as? String == "integer", n.rounded() != n { try fail("enter a whole number.") }
            if let min = schema["minimum"] as? Double, n < min { try fail("minimum is \(min).") }
            if let max = schema["maximum"] as? Double, n > max { try fail("maximum is \(max).") }
            if let min = schema["exclusiveMinimum"] as? Double, n <= min { try fail("must exceed \(min).") }
            if let max = schema["exclusiveMaximum"] as? Double, n >= max { try fail("must be less than \(max).") }
        case "string":
            guard let string = value as? String else { try fail("enter text."); return }
            if let min = schema["minLength"] as? Int, string.count < min { try fail("at least \(min) characters are required.") }
            if let max = schema["maxLength"] as? Int, string.count > max { try fail("at most \(max) characters are allowed.") }
            if let pattern = schema["pattern"] as? String {
                guard let regex = try? NSRegularExpression(pattern: pattern), regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else { try fail("text does not match the required format."); return }
            }
            switch schema["format"] as? String {
            case "uri": if URL(string: string)?.scheme == nil { try fail("enter an absolute URL.") }
            case "email": if string.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil { try fail("enter an email address.") }
            case "date":
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                guard let date = formatter.date(from: string), formatter.string(from: date) == string else { try fail("enter a date as YYYY-MM-DD."); return }
            case "date-time":
                let formatter = ISO8601DateFormatter()
                if formatter.date(from: string) == nil {
                    formatter.formatOptions.insert(.withFractionalSeconds)
                    if formatter.date(from: string) == nil { try fail("enter an ISO 8601 date and time.") }
                }
            default: break
            }
        default: try fail("unsupported field type.")
        }
    }
}

enum CodexProtocolJSON {
    static func object(_ raw: String?) -> [String: Any] {
        guard let raw, let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed]) else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }
    static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        guard let a = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys, .fragmentsAllowed]),
              let b = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
        return a == b
    }
}

struct CodexSkill: Identifiable, Equatable {
    let name: String
    let path: String
    let description: String
    let scope: String
    let enabled: Bool
    let displayName: String
    let shortDescription: String
    let dependencySummary: String
    var id: String { path }
    var input: [String: Any] { ["type": "skill", "name": name, "path": path] }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty,
              let path = json["path"] as? String, path.hasPrefix("/") else { return nil }
        self.name = name; self.path = path
        description = json["description"] as? String ?? ""
        scope = json["scope"] as? String ?? "unknown"
        enabled = json["enabled"] as? Bool ?? true
        let interface = json["interface"] as? [String: Any] ?? [:]
        displayName = (interface["displayName"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? name
        shortDescription = (interface["shortDescription"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? (json["shortDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? description
        let tools = (json["dependencies"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        dependencySummary = tools.map { [$0["type"] as? String, $0["value"] as? String, $0["description"] as? String].compactMap { $0 }.joined(separator: ": ") }.joined(separator: "\n")
    }
}

struct CodexExtensionEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    var detail: String = ""
    var status: String = ""
    var enabled: Bool? = nil
    var url: URL? = nil
    var installed: Bool? = nil
    var rawPluginID: String? = nil
    var pluginName: String? = nil
    var marketplacePath: String? = nil
    var remoteMarketplaceName: String? = nil
    var canInstall: Bool = false

    var mentionPath: String? {
        guard enabled != false else { return nil }
        if kind == "App", status == "Available" {
            return "app://" + String(id.dropFirst("App:".count))
        }
        if kind == "Plugin", installed == true, let rawPluginID, rawPluginID.contains("@") {
            return "plugin://" + rawPluginID
        }
        return nil
    }

}

struct CodexCollaborationMode: Identifiable, Equatable {
    let id: String
    let name: String
    let mode: String
    let model: String?
    let effort: String?

    init?(json: [String: Any]) {
        guard let mode = json["mode"] as? String else { return nil }
        name = json["name"] as? String ?? mode
        self.mode = mode
        model = json["model"] as? String
        effort = json["reasoning_effort"] as? String
        id = "\(mode):\(name)"
    }

    func input(model selectedModel: String, effort selectedEffort: String?) -> [String: Any] {
        ["mode": mode, "settings": ["model": selectedModel,
            "reasoning_effort": (selectedEffort ?? effort) as Any? ?? NSNull(), "developer_instructions": NSNull()]]
    }
}

/// Structured result assets remain distinct from model-authored text. Extraction
/// does not fetch URLs, read files, or execute MCP app HTML.
struct CodexArtifact: Identifiable, Equatable {
    let id: String
    let label: String
    let source: String
    let mimeType: String?
    var isImage: Bool {
        if mimeType?.hasPrefix("image/") == true || source.hasPrefix("data:image/") { return true }
        let ext = URL(string: source)?.pathExtension.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }

    static func extract(from rawJSON: String) -> [CodexArtifact] {
        guard rawJSON.utf8.count <= 80_000_000,
              let item = try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any] else { return [] }
        var result: [CodexArtifact] = []
        var seen = Set<String>()
        func append(_ source: String?, _ label: String, _ mime: String? = nil) {
            guard let source, !source.isEmpty, source.utf8.count <= 70_000_000,
                  result.count < 40, seen.insert(source).inserted else { return }
            result.append(CodexArtifact(id: "artifact-\(result.count)", label: label, source: source, mimeType: mime))
        }
        func content(_ block: [String: Any]) {
            let type = block["type"] as? String ?? ""
            let label = block["name"] as? String ?? block["title"] as? String ?? "Result"
            switch type {
            case "image":
                let mime = block["mimeType"] as? String ?? "image/png"
                if let data = block["data"] as? String { append("data:\(mime);base64,\(data)", "Image", mime) }
                else { append(block["url"] as? String, "Image", mime) }
            case "inputImage": append(block["imageUrl"] as? String, "Image", "image/png")
            case "localImage": append(block["path"] as? String, "Attached image", "image/png")
            case "resource_link", "resourceLink": append(block["uri"] as? String, label, block["mimeType"] as? String)
            case "resource":
                guard let resource = block["resource"] as? [String: Any] else { break }
                let mime = resource["mimeType"] as? String
                if let mime, mime.hasPrefix("image/"), let blob = resource["blob"] as? String {
                    append("data:\(mime);base64,\(blob)", label, mime)
                } else { append(resource["uri"] as? String, label, mime) }
            default: break
            }
        }
        switch item["type"] as? String {
        case "imageView": append(item["path"] as? String, "Viewed image", "image/png")
        case "imageGeneration":
            if let path = item["savedPath"] as? String { append(path, "Generated image", "image/png") }
            else if let value = item["result"] as? String, !value.isEmpty {
                let source = value.hasPrefix("/") || value.hasPrefix("https://") || value.hasPrefix("data:image/")
                    ? value : "data:image/png;base64,\(value)"
                append(source, "Generated image", "image/png")
            }
        case "mcpToolCall":
            if let output = item["result"] as? [String: Any] {
                for block in output["content"] as? [[String: Any]] ?? [] { content(block) }
            }
            if let app = item["mcpAppUi"] as? [String: Any] { append(app["resourceUri"] as? String, "Plugin application") }
            else if let app = item["appContext"] as? [String: Any] { append(app["resourceUri"] as? String, "Plugin application") }
        case "dynamicToolCall":
            for block in item["contentItems"] as? [[String: Any]] ?? [] { content(block) }
        case "userMessage":
            for block in item["content"] as? [[String: Any]] ?? [] { content(block) }
        default: break
        }
        return result
    }
}
