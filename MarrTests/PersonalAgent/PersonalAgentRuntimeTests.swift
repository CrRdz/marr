import Foundation
import XCTest
@testable import Marr

@MainActor
final class PersonalAgentRuntimeTests: XCTestCase {
    func testEveryTurnOverridesInheritedWriteRootsAndApprovalReviewer() throws {
        var agent = PersonalAgentProfile(access: .workspace)
        let run = PersonalAgentRun(agentID: agent.id, prompt: "Draft")
        var execution = PersonalAgentExecution(agent: agent, run: run, skills: [], directory: URL(fileURLWithPath: "/tmp/only-this-agent"), model: "test")
        let params = PersonalAgentRuntime.turnParameters(execution, threadID: "thread")
        let sandbox = try XCTUnwrap(params["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(sandbox["type"] as? String, "workspaceWrite")
        XCTAssertEqual(sandbox["writableRoots"] as? [String], ["/tmp/only-this-agent"])
        XCTAssertEqual(sandbox["networkAccess"] as? Bool, false)
        XCTAssertEqual(sandbox["excludeSlashTmp"] as? Bool, true)
        XCTAssertEqual(sandbox["excludeTmpdirEnvVar"] as? Bool, true)
        XCTAssertEqual(params["approvalsReviewer"] as? String, "user")
        XCTAssertEqual(params["clientUserMessageId"] as? String, run.id.uuidString)
        agent.access = .readOnly; execution.agent = agent
        let readOnly = try XCTUnwrap(PersonalAgentRuntime.turnParameters(execution, threadID: "thread")["sandboxPolicy"] as? [String: Any])
        XCTAssertEqual(readOnly["type"] as? String, "readOnly")
        XCTAssertNil(readOnly["writableRoots"])
    }

    func testRuntimeResumesOwnThreadAppliesSandboxAndFiltersOtherThreadEvents() async throws {
        let transport = AgentTestTransport()
        transport.handler = { message, transport in
            guard let method = message["method"] as? String, let id = message["id"] else { return }
            var result: [String: Any] = [:]
            switch method {
            case "config/read": result = ["config": ["mcp_servers": ["email": [:]]]]
            case "thread/read": result = ["thread": ["id": "own-thread", "turns": []]]
            case "thread/resume": result = ["thread": ["id": "own-thread"]]
            case "turn/start": result = ["turn": ["id": "own-turn"]]
            default: break
            }
            transport.push(["id": id, "result": result])
            if method == "turn/start" {
                transport.push(["method": "turn/started", "params": ["threadId": "own-thread", "turn": ["id": "own-turn"]]])
                transport.push(["method": "item/completed", "params": ["threadId": "other-thread", "item": ["id": "foreign", "type": "agentMessage", "text": "Do not show"]]])
                transport.push(["id": "foreign-approval", "method": "item/commandExecution/requestApproval", "params": ["threadId": "other-thread", "turnId": "other-turn", "command": "bad"]])
                transport.push(["method": "item/completed", "params": ["threadId": "own-thread", "turnId": "own-turn", "item": ["id": "answer", "type": "agentMessage", "phase": "final_answer", "text": "Verified result"]]])
                transport.push(["method": "turn/completed", "params": ["threadId": "own-thread", "turn": ["id": "own-turn", "status": "completed"]]])
            }
        }
        let runtime = PersonalAgentRuntime(transport: transport)
        defer { runtime.close() }
        let agent = PersonalAgentProfile(memory: "Keep answers concise.")
        let execution = PersonalAgentExecution(agent: agent, run: PersonalAgentRun(agentID: agent.id, prompt: "Check", threadID: "own-thread"),
            skills: [PersonalAgentSkill(name: "Verify", instructions: "Use primary sources")], directory: URL(fileURLWithPath: "/tmp/marr-agent"), model: "test-model")
        var events = 0, interactionCount = 0
        let result = try await runtime.run(execution) { event in
            events += 1
            if case .interaction = event { interactionCount += 1 }
        }
        XCTAssertEqual(result.text, "Verified result")
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertGreaterThan(events, 1)
        XCTAssertEqual(interactionCount, 0)
        XCTAssertTrue(transport.messages.contains { $0["id"] as? String == "foreign-approval" && $0["error"] != nil })
        let resume = try XCTUnwrap(transport.messages.first { $0["method"] as? String == "thread/resume" }?["params"] as? [String: Any])
        XCTAssertEqual(resume["threadId"] as? String, "own-thread")
        XCTAssertEqual(resume["sandbox"] as? String, "read-only")
        XCTAssertEqual(resume["approvalPolicy"] as? String, "on-request")
        let config = try XCTUnwrap(resume["config"] as? [String: Any])
        XCTAssertEqual(config["mcp_servers.email.enabled"] as? Bool, false)
        XCTAssertEqual(config["features.apps"] as? Bool, false)
        XCTAssertTrue((resume["developerInstructions"] as? String)?.contains("Keep answers concise.") == true)
        XCTAssertTrue((resume["developerInstructions"] as? String)?.contains("Use primary sources") == true)
        XCTAssertFalse(transport.messages.contains { $0["method"] as? String == "thread/start" })
    }

    func testReconciliationNeverTreatsEarlierTurnAsUnacknowledgedRunOrReplaysWork() async throws {
        let transport = AgentTestTransport()
        transport.handler = { message, transport in
            guard let id = message["id"], let method = message["method"] as? String else { return }
            let result: [String: Any] = method == "thread/read" ? ["thread": ["turns": [["id": "old-turn", "status": "completed"]]]] : [:]
            transport.push(["id": id, "result": result])
        }
        let runtime = PersonalAgentRuntime(transport: transport)
        defer { runtime.close() }
        let result = try await runtime.reconcile(threadID: "thread", turnID: nil)
        XCTAssertNil(result)
        XCTAssertEqual(transport.messages.compactMap { $0["method"] as? String }, ["initialize", "initialized", "thread/read"])
    }

    func testApprovalRequiresExplicitResponseAndPreservesRequestIdentity() async throws {
        let transport = AgentTestTransport()
        transport.handler = { message, transport in
            if let id = message["id"], let method = message["method"] as? String {
                let result: [String: Any] = method == "thread/start" ? ["thread": ["id": "thread"]]
                    : method == "turn/start" ? ["turn": ["id": "turn"]] : [:]
                transport.push(["id": id, "result": result])
                if method == "turn/start" {
                    transport.push(["id": "approve-1", "method": "item/fileChange/requestApproval", "params": ["threadId": "thread", "turnId": "turn", "reason": "Write a draft"]])
                }
            } else if message["id"] as? String == "approve-1" {
                transport.push(["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn", "status": "completed"]]])
            }
        }
        let runtime = PersonalAgentRuntime(transport: transport)
        defer { runtime.close() }
        let agent = PersonalAgentProfile()
        let execution = PersonalAgentExecution(agent: agent, run: PersonalAgentRun(agentID: agent.id, prompt: "Prepare draft"),
            skills: [], directory: URL(fileURLWithPath: "/tmp/marr-agent"), model: "test")
        var received = false
        _ = try await runtime.run(execution) { event in
            if case .interaction(let request) = event {
                received = true
                XCTAssertFalse(transport.messages.contains { $0["id"] as? String == "approve-1" })
                Task { try await runtime.respond(request, result: request.response(action: .decline)) }
            }
        }
        XCTAssertTrue(received)
        XCTAssertEqual((transport.messages.first { $0["id"] as? String == "approve-1" }?["result"] as? [String: String])?["decision"], "decline")
    }

    func testLostTurnAcknowledgementIsRecoveredByPersistedClientMessageID() async throws {
        let transport = AgentTestTransport()
        transport.handler = { message, transport in
            guard let id = message["id"], let method = message["method"] as? String else { return }
            let turns: [[String: Any]] = [
                ["id": "old", "status": "completed", "items": []],
                ["id": "actual", "status": "inProgress", "items": [["type": "userMessage", "clientId": "durable-run-id"]]]
            ]
            transport.push(["id": id, "result": method == "thread/read" ? ["thread": ["turns": turns]] : [:]])
        }
        let runtime = PersonalAgentRuntime(transport: transport)
        defer { runtime.close() }
        let result = try await runtime.reconcile(threadID: "thread", turnID: nil, clientID: "durable-run-id")
        XCTAssertEqual(result?.status, .uncertain)
        XCTAssertEqual(result?.turnID, "actual")
        XCTAssertFalse(transport.messages.contains { ["turn/start", "thread/resume", "turn/interrupt"].contains($0["method"] as? String ?? "") })
    }

    func testExplicitTurnRejectionDoesNotClaimWorkMayStillBeRunning() async throws {
        let transport = AgentTestTransport()
        transport.handler = { message, transport in
            guard let id = message["id"], let method = message["method"] as? String else { return }
            if method == "turn/start" {
                transport.push(["id": id, "error": ["code": -32000, "message": "Model unavailable"]])
            } else {
                transport.push(["id": id, "result": method == "thread/start" ? ["thread": ["id": "thread"]] : [:]])
            }
        }
        let runtime = PersonalAgentRuntime(transport: transport)
        defer { runtime.close() }
        let agent = PersonalAgentProfile()
        do {
            _ = try await runtime.run(PersonalAgentExecution(agent: agent, run: PersonalAgentRun(agentID: agent.id, prompt: "Hello"),
                skills: [], directory: URL(fileURLWithPath: "/tmp/marr-agent"), model: "test")) { _ in }
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error.localizedDescription, "Model unavailable") }
        XCTAssertFalse(runtime.didSubmit)
    }

    func testStopWaitsForRuntimeConfirmationAndTargetsOnlyActiveTurn() async throws {
        let transport = AgentTestTransport()
        transport.handler = { message, transport in
            guard let id = message["id"], let method = message["method"] as? String else { return }
            let result: [String: Any] = method == "thread/start" ? ["thread": ["id": "thread"]]
                : method == "turn/start" ? ["turn": ["id": "turn"]] : [:]
            transport.push(["id": id, "result": result])
            if method == "turn/interrupt" {
                XCTAssertEqual((message["params"] as? [String: String])?["turnId"], "turn")
                transport.push(["method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "turn", "status": "interrupted"]]])
            }
        }
        let runtime = PersonalAgentRuntime(transport: transport)
        defer { runtime.close() }
        let agent = PersonalAgentProfile()
        let result = try await runtime.run(PersonalAgentExecution(agent: agent, run: PersonalAgentRun(agentID: agent.id, prompt: "Hello"),
            skills: [], directory: URL(fileURLWithPath: "/tmp/marr-agent"), model: "test")) { event in
            if case .turn = event { Task { await runtime.stop() } }
        }
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(transport.messages.contains { $0["method"] as? String == "turn/interrupt" })
    }
}

@MainActor
private final class AgentTestTransport: PersonalAgentTransport {
    var messages: [[String: Any]] = []
    var handler: (([String: Any], AgentTestTransport) -> Void)?
    private var queue: [[String: Any]] = []
    private var waiter: CheckedContinuation<[String: Any], Error>?
    func start() {}
    func send(_ message: [String: Any]) async throws { messages.append(message); handler?(message, self) }
    func receive() async throws -> [String: Any] {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func push(_ message: [String: Any]) {
        if let waiter { self.waiter = nil; waiter.resume(returning: message) }
        else { queue.append(message) }
    }
    func close() { waiter?.resume(throwing: CancellationError()); waiter = nil }
}
