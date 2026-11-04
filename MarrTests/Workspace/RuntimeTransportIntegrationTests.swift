import Foundation
import XCTest
@testable import Marr

/// Real URLSessionWebSocketTask tests against the isolated loopback service
/// started outside the sandbox by scripts/test-marr.sh. No app windows, accounts,
/// credentials, Codex executable or model requests are involved.
@MainActor
final class CodexTransportIntegrationTests: XCTestCase {
    func testSwitchingHistoryReusesInitializedSocketWithoutModelOrCapabilityReload() async throws {
        let fixture = try LoopbackWorkspaceFixture(scenario: "large-history")
        defer { fixture.close() }
        for index in 0..<3 {
            let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
            let task = fixture.controller.workbench.upsertRemoteTask(workspaceID: workspaceID,
                threadID: "history-\(index)", title: "History \(index)", state: .completed,
                statusMessage: "Saved", createdAt: Date(), updatedAt: Date())
            XCTAssertTrue(fixture.controller.selectTask(task))
            try await waitUntil { !fixture.controller.isReadingSelectedTask && fixture.controller.latestAgentMessage == "Large history tail received" }
            XCTAssertEqual(fixture.controller.workbench.selectedTask?.threadID, "history-\(index)")
        }
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["initialize"], 1)
        XCTAssertEqual(counts["thread/read"], 3)
        XCTAssertEqual(counts["model/list"], 1)
        XCTAssertNil(counts["turn/start"])
        XCTAssertNil(counts["thread/resume"])
    }

    func testHistoryLargerThanDefaultWebSocketLimitLoadsWithoutReconnect() async throws {
        let fixture = try LoopbackWorkspaceFixture(scenario: "large-history")
        defer { fixture.close() }
        let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
        let task = fixture.controller.workbench.upsertRemoteTask(workspaceID: workspaceID,
            threadID: fixture.threadID, title: "Large history", state: .completed,
            statusMessage: "Saved", createdAt: Date(), updatedAt: Date())
        XCTAssertTrue(fixture.controller.selectTask(task))
        try await waitUntil { fixture.controller.latestAgentMessage == "Large history tail received" }
        XCTAssertTrue(fixture.controller.historyPreparationWasOffMain,
                      "Real history decoding and item formatting must finish off the UI thread")
        XCTAssertGreaterThan(try XCTUnwrap(fixture.controller.activities.first { $0.kind == .command }).detail.utf8.count, 2_000_000)
        XCTAssertFalse(fixture.controller.activities.contains { $0.kind == .error })
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["initialize"], 1)
        XCTAssertEqual(counts["thread/read"], 1)
        XCTAssertNil(counts["thread/resume"])
        XCTAssertNil(counts["turn/start"])
    }

    func testRealWebSocketInitializationHandlesFragmentedFramesAndBatchedJSON() async throws {
        let fixture = try LoopbackWorkspaceFixture(scenario: "fragments")
        defer { fixture.close() }
        fixture.controller.refreshModels()
        try await waitUntil { !fixture.controller.isLoadingModels && !fixture.controller.availableModels.isEmpty }
        XCTAssertEqual(fixture.controller.runtimeDescription, "Marr loopback fixture")
        XCTAssertEqual(fixture.controller.availableModels.first?.name, "模型 分片")
        try await waitUntil { fixture.controller.capabilityErrors["warning"] != nil }
        XCTAssertEqual(fixture.controller.capabilityErrors["warning"], "fixture 分片 decoded")
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["initialize"], 1)
        XCTAssertEqual(counts["initialized"], 1)
        XCTAssertEqual(counts["model/list"], 1)
        XCTAssertNil(counts["turn/start"])
    }

    func testRealSocketDisconnectReconcilesWithoutReplayingAcceptedTurn() async throws {
        let fixture = try LoopbackWorkspaceFixture(scenario: "disconnect")
        defer { fixture.close() }
        XCTAssertTrue(fixture.controller.submit(prompt: "Local fixture only", images: []))
        try await waitUntil { fixture.controller.workbench.selectedTask?.state == .completed && fixture.controller.canSubmit }
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Fixture completed")
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertEqual(fixture.controller.recoverableDrafts.count, 1, "An ambiguous submission remains available for explicit user inspection")
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["turn/start"], 1)
        XCTAssertEqual(counts["thread/start"], 1)
        XCTAssertEqual(counts["thread/read"], 1)
        XCTAssertEqual(counts["initialize"], 2)
        XCTAssertNil(counts["thread/resume"])
        XCTAssertNil(counts["client-response"], "Reconnection must not answer an approval")
    }

    func testRealRequestDeadlineClosesUnacknowledgedTurnAndOnlyReadsAfterReconnect() async throws {
        let fixture = try LoopbackWorkspaceFixture(scenario: "timeout", requestTimeout: 0.75)
        defer { fixture.close() }
        XCTAssertTrue(fixture.controller.submit(prompt: "Intentionally unacknowledged local fixture", images: []))
        try await waitUntil { fixture.controller.workbench.selectedTask?.state == .completed && fixture.controller.canSubmit }
        XCTAssertTrue(fixture.controller.recoverableDrafts.first?.error?.contains("not acknowledged the turn start") == true,
                      "This path must be completed by the production RPC timer, not an injected expiry call")
        let counts = try await fixture.counts()
        XCTAssertEqual(counts["turn/start"], 1)
        XCTAssertEqual(counts["thread/read"], 1)
        XCTAssertEqual(counts["initialize"], 2)
        XCTAssertNil(counts["thread/resume"])
        XCTAssertNil(counts["turn/steer"])
    }

    func testManagedChildFallbackReuseAndSyncOffCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MarrManagedChild-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtureScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/marr-loopback-test-server.py")
        let launcher = root.appendingPathComponent("runtime")
        let quotedScript = "'" + fixtureScript.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        try Data(("#!/bin/sh\nexec /usr/bin/python3 " + quotedScript + " --codex-child \"$@\"\n").utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let failure = root.appendingPathComponent("unsupported-runtime")
        try Data("#!/bin/sh\necho unsupported-app-server >&2\nexit 2\n".utf8).write(to: failure)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failure.path)
        let controller = RuntimeWorkspaceController(defaults: defaults, attachmentDirectory: root.appendingPathComponent("attachments"),
            codexSyncEnabled: true, runtimeExecutables: [failure, launcher])
        defer {
            controller.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        controller.refreshModels()
        try await waitUntil { !controller.availableModels.isEmpty }
        let child = try XCTUnwrap(controller.managedServerProcess)
        XCTAssertTrue(child.isRunning)
        XCTAssertEqual(controller.runtimeDescription, "Marr loopback fixture")
        let endpoint = controller.appServerURLString
        controller.refreshModels()
        try await waitUntil { !controller.isLoadingModels }
        XCTAssertTrue(controller.managedServerProcess === child)
        XCTAssertEqual(controller.appServerURLString, endpoint)
        XCTAssertTrue(controller.setCodexSyncEnabled(false))
        try await waitUntil { !child.isRunning }
        XCTAssertNil(controller.managedServerProcess)
    }

    func testSeparateMarrInstancesOwnSeparateChildrenAndShutdownIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("runtime")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/marr-loopback-test-server.py")
        let quoted = "'" + script.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        try Data(("#!/bin/sh\nexec /usr/bin/python3 " + quoted + " --codex-child \"$@\"\n").utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let suiteA = "MarrChildA-\(UUID().uuidString)", suiteB = "MarrChildB-\(UUID().uuidString)"
        let aDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let bDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        let a = RuntimeWorkspaceController(defaults: aDefaults, attachmentDirectory: root.appendingPathComponent("a"),
            codexSyncEnabled: true, runtimeExecutables: [launcher])
        let b = RuntimeWorkspaceController(defaults: bDefaults, attachmentDirectory: root.appendingPathComponent("b"),
            codexSyncEnabled: true, runtimeExecutables: [launcher])
        defer {
            a.shutdown(); b.shutdown()
            aDefaults.removePersistentDomain(forName: suiteA); bDefaults.removePersistentDomain(forName: suiteB)
        }
        a.refreshModels(); b.refreshModels()
        try await waitUntil { !a.availableModels.isEmpty && !b.availableModels.isEmpty }
        let aChild = try XCTUnwrap(a.managedServerProcess), bChild = try XCTUnwrap(b.managedServerProcess)
        XCTAssertNotEqual(a.appServerURLString, b.appServerURLString)
        a.shutdown()
        try await waitUntil { !aChild.isRunning }
        XCTAssertTrue(bChild.isRunning)
        b.shutdown()
        try await waitUntil { !bChild.isRunning }
    }

    func testShutdownDuringReadinessStopsPendingChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let launcher = root.appendingPathComponent("slow-runtime")
        try Data("#!/bin/sh\nexec /usr/bin/python3 -c 'import time; time.sleep(30)'\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let suite = "MarrStartupCancellation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = RuntimeWorkspaceController(defaults: defaults, attachmentDirectory: root.appendingPathComponent("attachments"),
            codexSyncEnabled: true, runtimeExecutables: [launcher])
        defer {
            controller.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        controller.refreshModels()
        try await waitUntil { controller.managedServerProcess?.isRunning == true }
        let child = try XCTUnwrap(controller.managedServerProcess)
        controller.shutdown()
        try await waitUntil { !child.isRunning }
        XCTAssertNil(controller.managedServerProcess)
        XCTAssertFalse(controller.isLoadingModels)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("The loopback app-server did not reach the expected state within ten seconds")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class LoopbackWorkspaceFixture {
    let controller: RuntimeWorkspaceController
    let threadID: String
    private let defaults: UserDefaults
    private let suite: String
    private let root: URL
    private let metricsURL: URL

    init(scenario: String, requestTimeout: TimeInterval? = nil) throws {
        guard let raw = ProcessInfo.processInfo.environment["MARR_TEST_APP_SERVER_URL"], !raw.isEmpty else {
            throw XCTSkip("Loopback transport tests require scripts/test-marr.sh; no real runtime is used as a fallback.")
        }
        guard var components = URLComponents(string: raw), components.scheme == "ws",
              components.host == "127.0.0.1", components.port != nil,
              components.user == nil, components.password == nil else {
            throw NSError(domain: "MarrLoopbackFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The fixture endpoint must be loopback ws://127.0.0.1:<port>"])
        }
        let token = UUID().uuidString
        threadID = "fixture-" + token
        suite = "Marr.Loopback.\(token)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkbenchStore(defaults: defaults)
        _ = store.upsertWorkspace(url: root, bookmark: Data())
        defaults.set(Data(), forKey: "codex.workspace.bookmark")
        components.path = "/\(scenario)/\(token)"
        let endpoint = try XCTUnwrap(components.url)
        components.scheme = "http"
        components.path = "/metrics/\(token)"
        metricsURL = try XCTUnwrap(components.url)
        controller = RuntimeWorkspaceController(defaults: defaults,
            attachmentDirectory: root.appendingPathComponent("Attachments"),
            requestTimeout: requestTimeout, codexSyncEnabled: true)
        controller.setAppServerURL(endpoint.absoluteString)
    }

    func counts() async throws -> [String: Int] {
        var request = URLRequest(url: metricsURL)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
    }

    func close() {
        controller.setAppServerURL("")
        controller.flushPendingTaskSnapshot()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
