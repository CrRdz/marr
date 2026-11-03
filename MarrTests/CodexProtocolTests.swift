import Foundation
import XCTest
@testable import Marr

final class CodexProtocolTests: XCTestCase {
    func testSettingsModelsPreserveUnavailableUsageAndClampRemainingPercentage() throws {
        let bucket = CodexRateLimitBucket(id: "codex", json: ["primary": ["usedPercent": 130, "resetsAt": 1_800_000_000], "secondary": NSNull()])
        XCTAssertEqual(bucket.primary?.usedPercent, 130)
        XCTAssertEqual(bucket.primary?.remainingPercent, 0)
        XCTAssertEqual(bucket.primary?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(bucket.secondary)
        XCTAssertNil(bucket.hasCredits)
        XCTAssertNil(CodexRateLimitWindow(json: ["usedPercent": true]))
        let usage = try XCTUnwrap(CodexAccountUsage(json: ["summary": ["lifetimeTokens": NSNull(), "currentStreakDays": 0]]))
        XCTAssertNil(usage.lifetimeTokens)
        XCTAssertEqual(usage.currentStreakDays, 0)
        XCTAssertNil(usage.dailyUsageBuckets)
    }

    func testAccountLoginOnlyExposesSafeBrowserURLs() {
        for url in ["https://auth.openai.com/login", "http://localhost:1455/auth", "http://127.0.0.1:1455/auth"] {
            XCTAssertNotNil(CodexAccountLogin(json: ["type": "chatgpt", "loginId": "login", "authUrl": url])?.url)
        }
        for url in ["http://remote.example/login", "file:///tmp/login", "javascript:alert(1)"] {
            XCTAssertNil(CodexAccountLogin(json: ["type": "chatgpt", "loginId": "login", "authUrl": url])?.url)
        }
    }

    func testConfigurationKeepsBaseUserVersionAndHumanReadableRequirements() throws {
        let config = try XCTUnwrap(CodexConfiguration(json: ["config": ["web_search": "cached", "api_key": "not displayed"], "layers": [
            ["name": ["type": "user", "file": "/tmp/config.toml", "profile": "work"], "version": "profile-version", "config": [:]],
            ["name": ["type": "user", "file": "/tmp/config.toml"], "version": "base-version", "config": [:]]
        ], "origins": ["web_search": ["name": ["type": "project", "dotCodexFolder": "/tmp/.codex"], "version": "project"]]]))
        XCTAssertEqual(config.userVersion, "base-version")
        XCTAssertEqual(config.origins["web_search"], "project")
        let requirements = CodexConfigurationRequirements(json: ["allowedSandboxModes": ["read-only", "workspace-write"], "allowBrowserAndComputerUse": false])
        XCTAssertTrue(requirements.summary.contains("Read Only, Workspace Write"))
        XCTAssertTrue(requirements.summary.contains("Browser and computer access: Disabled"))
        XCTAssertFalse(requirements.summary.contains("{"))
        let feature = try XCTUnwrap(CodexExperimentalFeature(json: ["name": "feature_key", "stage": "beta", "enabled": false, "defaultEnabled": true]))
        XCTAssertEqual(feature.displayName, "Feature Key")
    }

    func testRequestIDsPreserveWireTypeAndRejectInvalidNumbers() {
        XCTAssertEqual(CodexRequestID("42"), .string("42"))
        XCTAssertEqual(CodexRequestID(42), .integer(42))
        XCTAssertNotEqual(CodexRequestID("42"), CodexRequestID(42))
        XCTAssertNil(CodexRequestID(true))
        XCTAssertNil(CodexRequestID(1.5))
        XCTAssertNil(CodexRequestID(NSNull()))
    }

    func testQuestionRepliesUseAnswersAndRequireEveryQuestion() throws {
        let request = questionRequest()
        XCTAssertThrowsError(try request.response(action: .accept))
        let reply = try request.response(action: .accept, answers: ["q1": ["Yes"]])
        let answers = try XCTUnwrap(reply["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["q1"]?["answers"], ["Yes"])
        XCTAssertNil(reply["decision"])
        XCTAssertEqual((try request.response(action: .cancel))["answers"] as? [String: String], [:])
    }

    func testClosedChoiceQuestionsDoNotAcceptMadeUpChoice() {
        XCTAssertThrowsError(try questionRequest().response(action: .accept, answers: ["q1": ["made up"]]))
    }

    func testPermissionsGrantOnlyRequestedNonNullFieldsForThisTurn() throws {
        let request = interaction("item/permissions/requestApproval", ["permissions": [
            "network": ["enabled": true], "fileSystem": NSNull(), "unexpected": "ignored"
        ]])
        let accepted = try request.response(action: .accept)
        let permissions = try XCTUnwrap(accepted["permissions"] as? [String: Any])
        XCTAssertEqual((permissions["network"] as? [String: Bool])?["enabled"], true)
        XCTAssertNil(permissions["fileSystem"])
        XCTAssertNil(permissions["unexpected"])
        XCTAssertEqual(accepted["scope"] as? String, "turn")
        XCTAssertTrue(((try request.response(action: .decline))["permissions"] as? [String: Any])?.isEmpty == true)
    }

    func testElicitationFormConvertsTypesAndValidatesConstraints() throws {
        let request = formRequest()
        XCTAssertTrue(request.supportsAcceptance)
        XCTAssertThrowsError(try request.response(action: .accept, formValues: ["count": "0", "enabled": "true", "name": "x"]))
        XCTAssertThrowsError(try request.response(action: .accept, formValues: ["count": "true", "enabled": "true", "name": "valid"]))
        let reply = try request.response(action: .accept, formValues: ["count": "2", "enabled": "false", "name": "valid"])
        let content = try XCTUnwrap(reply["content"] as? [String: Any])
        XCTAssertEqual(content["count"] as? Int, 2)
        XCTAssertEqual(content["enabled"] as? Bool, false)
        XCTAssertEqual(content["name"] as? String, "valid")
        XCTAssertEqual(reply["action"] as? String, "accept")
        XCTAssertTrue(reply["_meta"] is NSNull)
    }

    func testDeclineAndCancelElicitationAreValidWithoutFormValues() throws {
        for action in [CodexInteractionAction.decline, .cancel] {
            let reply = try formRequest().response(action: action)
            XCTAssertEqual(reply["action"] as? String, action.rawValue)
            XCTAssertTrue(reply["content"] is NSNull)
            XCTAssertNil(reply["decision"])
        }
    }

    func testRequiredStringCanBeEmptyUnlessSchemaRequiresLength() throws {
        let request = interaction("mcpServer/elicitation/request", ["mode": "form", "requestedSchema": [
            "type": "object", "required": ["note"], "properties": ["note": ["type": "string"]]]])
        let content = try XCTUnwrap(request.response(action: .accept, formValues: ["note": ""])["content"] as? [String: Any])
        XCTAssertEqual(content["note"] as? String, "")
        XCTAssertThrowsError(try CodexFormValidation.validate("", schema: ["type": "string", "minLength": 1], path: "note"))
    }

    func testUnsupportedSchemaIsVisibleButCannotBeAccepted() {
        let request = interaction("mcpServer/elicitation/request", ["mode": "openai/form", "requestedSchema": [
            "type": "object", "oneOf": [["required": ["a"]], ["required": ["b"]]]
        ]])
        XCTAssertFalse(request.supportsAcceptance)
        XCTAssertThrowsError(try request.response(action: .accept))
        XCTAssertNoThrow(try request.response(action: .cancel))
    }

    func testTitledSingleAndMultipleChoiceFormsKeepWireValues() throws {
        let choices: [[String: Any]] = [["const": "r", "title": "Read"], ["const": "w", "title": "Write"]]
        let request = interaction("mcpServer/elicitation/request", ["mode": "form", "requestedSchema": [
            "type": "object", "required": ["single", "multiple"], "properties": [
                "single": ["type": "string", "oneOf": choices],
                "multiple": ["type": "array", "minItems": 1, "maxItems": 2, "items": ["anyOf": choices]]]]])
        XCTAssertTrue(request.supportsAcceptance)
        let field = try XCTUnwrap(request.formFields.first { $0.name == "multiple" })
        XCTAssertEqual(field.options, ["r", "w"])
        XCTAssertEqual(field.optionTitles["r"], "Read")
        let response = try request.response(action: .accept, formValues: ["single": "r", "multiple": "[\"r\",\"w\"]"])
        let content = try XCTUnwrap(response["content"] as? [String: Any])
        XCTAssertEqual(content["single"] as? String, "r")
        XCTAssertEqual(content["multiple"] as? [String], ["r", "w"])
        XCTAssertThrowsError(try request.response(action: .accept, formValues: ["single": "Read", "multiple": "[\"r\"]"]))
        XCTAssertThrowsError(try request.response(action: .accept, formValues: ["single": "r", "multiple": "[]"]))
        XCTAssertThrowsError(try request.response(action: .accept, formValues: ["single": "r", "multiple": "[\"invalid\"]"]))
    }

    func testLegacyEnumTitlesAndUnsupportedComposites() {
        let request = interaction("mcpServer/elicitation/request", ["mode": "form", "requestedSchema": ["type": "object", "properties": [
            "choice": ["type": "string", "enum": ["a", "b"], "enumNames": ["Option A", "Option B"]]]]])
        XCTAssertTrue(request.supportsAcceptance)
        XCTAssertEqual(request.formFields.first?.optionTitles["b"], "Option B")
        XCTAssertFalse(CodexFormValidation.supports(["type": "string", "oneOf": [["type": "string", "minLength": 2]]]))
        XCTAssertFalse(CodexFormValidation.supports(["anyOf": [["const": "a", "title": "A", "pattern": "a"]]]))
    }

    func testFormArrayAndNestedObjectValidation() throws {
        let schema: [String: Any] = ["type": "array", "minItems": 1, "uniqueItems": true,
            "items": ["type": "object", "required": ["id"], "additionalProperties": false,
                      "properties": ["id": ["type": "integer", "minimum": 1]]]]
        XCTAssertNoThrow(try CodexFormValidation.validate([["id": 2]], schema: schema, path: "items"))
        XCTAssertThrowsError(try CodexFormValidation.validate([["id": 2], ["id": 2]], schema: schema, path: "items"))
        XCTAssertThrowsError(try CodexFormValidation.validate([["id": 2, "extra": 3]], schema: schema, path: "items"))
        XCTAssertThrowsError(try CodexFormValidation.validate([["id": false]], schema: schema, path: "items"))
    }

    func testElicitationURLDoesNotAllowExecutableOrLocalSchemes() {
        for url in ["javascript:alert(1)", "file:///tmp/secret", "data:text/html,a", "relative/path"] {
            let request = interaction("mcpServer/elicitation/request", ["mode": "url", "url": url])
            XCTAssertNil(request.url)
            XCTAssertFalse(request.supportsAcceptance)
        }
        let request = interaction("mcpServer/elicitation/request", ["mode": "url", "url": "https://example.com/authorize"])
        XCTAssertNotNil(request.url)
        XCTAssertTrue(request.supportsAcceptance)
    }

    func testDynamicToolsFailWithProtocolShapedResultAndUnknownMethodsThrow() throws {
        let reply = try interaction("item/tool/call", [:]).response(action: .decline)
        XCTAssertEqual(reply["success"] as? Bool, false)
        XCTAssertEqual((reply["contentItems"] as? [[String: Any]])?.first?["type"] as? String, "inputText")
        XCTAssertThrowsError(try interaction("future/request", [:]).response(action: .cancel))
    }

    func testRestrictedCommandDecisionsDoNotOfferInvalidAccept() {
        let request = interaction("item/commandExecution/requestApproval", ["availableDecisions": ["decline", "cancel"]])
        XCTAssertFalse(request.supportsAcceptance)
        XCTAssertThrowsError(try request.response(action: .accept))
    }

    func testApprovalAlternativesPreserveServerDecisionAndNeverUpgradeOrdinaryAccept() throws {
        let network: [String: Any] = ["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "example.com", "action": "allow"]]]
        let command: [String: Any] = ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["git", "status"]]]
        let request = interaction("item/commandExecution/requestApproval", ["availableDecisions": ["acceptForSession", command, network, "decline", "cancel"]])
        XCTAssertFalse(request.supportsAcceptance)
        XCTAssertThrowsError(try request.response(action: .accept))
        XCTAssertEqual(request.approvalDecisions.count, 3)
        XCTAssertEqual(try request.approvalResponse(decision: request.approvalDecisions[0])["decision"] as? String, "acceptForSession")
        let reply = try request.approvalResponse(decision: request.approvalDecisions[2])
        XCTAssertTrue(CodexProtocolJSON.equal(try XCTUnwrap(reply["decision"]), network))
        XCTAssertThrowsError(try request.approvalResponse(decision: XCTUnwrap(CodexApprovalDecision("accept"))))
        let unexpected = try XCTUnwrap(CodexApprovalDecision(["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "different.example", "action": "allow"]]]))
        XCTAssertThrowsError(try request.approvalResponse(decision: unexpected))
        XCTAssertNil(CodexApprovalDecision(["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "example.com", "action": "unknown"]]]))
    }

    func testFileApprovalOffersExplicitSessionScopeAndNoCommandRule() throws {
        let request = interaction("item/fileChange/requestApproval", [:])
        XCTAssertEqual(request.approvalDecisions.compactMap { $0.rawValue as? String }, ["accept", "acceptForSession"])
        let command = try XCTUnwrap(CodexApprovalDecision(["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["git", "status"]]]))
        XCTAssertThrowsError(try request.approvalResponse(decision: command))
    }

    func testSkillPreservesExplicitIdentityScopeAndDependencies() throws {
        let skill = try XCTUnwrap(CodexSkill(json: ["name": "read-paper", "path": "/tmp/skills/read-paper/SKILL.md", "scope": "repo", "enabled": false,
            "interface": ["displayName": "Read a paper"], "dependencies": ["tools": [["type": "mcp", "value": "papers"]]]]))
        XCTAssertEqual(skill.displayName, "Read a paper")
        XCTAssertEqual(skill.scope, "repo")
        XCTAssertFalse(skill.enabled)
        XCTAssertTrue(skill.dependencySummary.contains("papers"))
        XCTAssertEqual(skill.input["type"] as? String, "skill")
        XCTAssertEqual(skill.input["path"] as? String, skill.path)
        XCTAssertNil(CodexSkill(json: ["name": "read-paper", "path": "relative/SKILL.md"]))
    }

    func testCollaborationModeUsesSelectedModelWithoutInjectingInstructions() throws {
        let mode = try XCTUnwrap(CodexCollaborationMode(json: ["name": "Plan", "mode": "plan", "model": "server-default", "reasoning_effort": "high"]))
        let input = mode.input(model: "user-selected", effort: "medium")
        let settings = try XCTUnwrap(input["settings"] as? [String: Any])
        XCTAssertEqual(input["mode"] as? String, "plan")
        XCTAssertEqual(settings["model"] as? String, "user-selected")
        XCTAssertEqual(settings["reasoning_effort"] as? String, "medium")
        XCTAssertTrue(settings["developer_instructions"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(input))
    }

    func testStructuredArtifactsKeepImagesAndResourceLinksWithoutScanningArguments() {
        let item: [String: Any] = ["type": "mcpToolCall", "arguments": ["secret": "https://example.com/not-a-result"],
            "result": ["content": [
                ["type": "image", "mimeType": "image/png", "data": "aW1hZ2U="],
                ["type": "resource_link", "uri": "file:///tmp/report.pdf", "name": "Report", "mimeType": "application/pdf"],
                ["type": "resource_link", "uri": "file:///tmp/report.pdf", "name": "Duplicate"]]]]
        let assets = CodexArtifact.extract(from: CodexProtocolJSON.pretty(item))
        XCTAssertEqual(assets.count, 2)
        XCTAssertTrue(assets[0].isImage)
        XCTAssertEqual(assets[0].source, "data:image/png;base64,aW1hZ2U=")
        XCTAssertFalse(assets[1].isImage)
        XCTAssertEqual(assets[1].label, "Report")
        XCTAssertFalse(assets.contains { $0.source.contains("not-a-result") })
    }

    func testGeneratedImageUsesSavedPathOrInlineResult() {
        let saved = CodexArtifact.extract(from: #"{"type":"imageGeneration","savedPath":"/tmp/generated.png","result":"aW1hZ2U="}"#)
        XCTAssertEqual(saved.first?.source, "/tmp/generated.png")
        let inline = CodexArtifact.extract(from: #"{"type":"imageGeneration","result":"aW1hZ2U="}"#)
        XCTAssertEqual(inline.first?.source, "data:image/png;base64,aW1hZ2U=")
        XCTAssertTrue(CodexArtifact.extract(from: "invalid JSON").isEmpty)
    }

    private func interaction(_ method: String, _ params: [String: Any]) -> CodexInteractionRequest {
        CodexInteractionRequest(id: .string("request-1"), method: method, params: params)
    }
    private func questionRequest() -> CodexInteractionRequest {
        interaction("item/tool/requestUserInput", ["questions": [["id": "q1", "header": "Proceed", "question": "Proceed?", "isOther": false,
            "options": [["label": "Yes", "description": "Continue"], ["label": "No", "description": "Stop"]]]]])
    }
    private func formRequest() -> CodexInteractionRequest {
        interaction("mcpServer/elicitation/request", ["mode": "form", "requestedSchema": ["type": "object",
            "required": ["count", "enabled", "name"], "properties": [
                "count": ["type": "integer", "minimum": 1, "maximum": 5], "enabled": ["type": "boolean"],
                "name": ["type": "string", "minLength": 2, "maxLength": 20]]]])
    }
}
