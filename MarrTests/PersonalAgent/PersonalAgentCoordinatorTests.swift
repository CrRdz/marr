import Foundation
import XCTest
@testable import Marr

@MainActor
final class PersonalAgentCoordinatorTests: XCTestCase {
    func testSuccessfulScheduledNoOpIsPersistedWithoutUnreadNotification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-coordinator-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalAgentStore(rootURL: root)
        let agent = store.archive.agents[0], now = Date()
        let routine = PersonalAgentRoutine(agentID: agent.id, name: "Check", instruction: "Check for changes", isEnabled: true)
        try store.save(routine, now: now.addingTimeInterval(-90_000))
        let executor = AgentExecutorStub()
        let coordinator = PersonalAgentCoordinator(store: store, endpoint: { URL(string: "ws://localhost:1")! },
            model: { "test" }, isReady: { true }, makeExecutor: { _ in executor })
        defer { coordinator.shutdown() }
        coordinator.tick(now: now)
        coordinator.tick(now: now)
        for _ in 0..<50 where coordinator.activeRunID != nil { await Task.yield() }
        XCTAssertEqual(executor.runs, 1)
        XCTAssertEqual(store.archive.runs.count, 1)
        XCTAssertEqual(store.archive.runs[0].status, .succeeded)
        XCTAssertEqual(store.archive.runs[0].threadID, "routine-thread")
        XCTAssertTrue(store.archive.runs[0].isRead)
        XCTAssertEqual(coordinator.unreadCount, 0)
        XCTAssertEqual(store.archive.routines[0].threadID, "routine-thread")
        XCTAssertNil(store.archive.agents[0].threadID, "Scheduled context must not replace the agent's chat")
    }

    func testDisconnectedRuntimeDoesNotConsumeScheduleOrCreateRun() throws {
        let store = PersonalAgentStore(rootURL: nil), now = Date()
        let agent = store.archive.agents[0]
        try store.save(PersonalAgentRoutine(agentID: agent.id, name: "Check", instruction: "Check", isEnabled: true), now: now.addingTimeInterval(-90_000))
        let coordinator = PersonalAgentCoordinator(store: store, endpoint: { XCTFail("Must not connect"); throw CancellationError() },
            model: { "test" }, isReady: { false })
        let next = store.archive.routines[0].nextRunAt
        coordinator.tick(now: now)
        XCTAssertFalse(coordinator.send("Hello", to: agent.id))
        XCTAssertTrue(store.archive.runs.isEmpty)
        XCTAssertEqual(store.archive.routines[0].nextRunAt, next)
    }

    func testTransportLossAfterSubmitIsUncertainAndNeverAutomaticallyRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marr-agent-loss-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalAgentStore(rootURL: root), agent = store.archive.agents[0]
        let executor = AgentExecutorStub(); executor.failAfterSubmit = true
        let coordinator = PersonalAgentCoordinator(store: store, endpoint: { URL(string: "ws://localhost:1")! },
            model: { "test" }, isReady: { true }, makeExecutor: { _ in executor })
        defer { coordinator.shutdown() }
        XCTAssertTrue(coordinator.send("Do work", to: agent.id))
        for _ in 0..<50 where coordinator.activeRunID != nil { await Task.yield() }
        XCTAssertEqual(store.archive.runs[0].status, .uncertain)
        XCTAssertFalse(coordinator.send("Do work", to: agent.id))
        XCTAssertEqual(executor.runs, 1)
        XCTAssertNil(store.archive.runs[0].finishedAt)
    }
}

@MainActor
private final class AgentExecutorStub: PersonalAgentExecuting {
    var didSubmit = false
    var runs = 0
    var failAfterSubmit = false
    func run(_ execution: PersonalAgentExecution, onEvent: @escaping (PersonalAgentRuntimeEvent) throws -> Void) async throws -> PersonalAgentOutcome {
        runs += 1
        try onEvent(.thread("routine-thread"))
        try onEvent(.submitting)
        didSubmit = true
        try onEvent(.turn("turn"))
        if failAfterSubmit { throw PersonalAgentFailure.message("Connection lost") }
        return PersonalAgentOutcome(status: .succeeded, text: "NO_UPDATE")
    }
    func respond(_ request: CodexInteractionRequest, result: [String: Any]) async throws {}
    func stop() async {}
    func close() {}
    func reconcile(threadID: String, turnID: String?, clientID: String?, stopIfRunning: Bool) async throws -> PersonalAgentOutcome? { nil }
}

@MainActor
final class PersonalAgentCloudTests: XCTestCase {
    func testEndpointRequiresTLSAndRejectsCredentialsPathsAndQueries() throws {
        for address in ["http://example.com", "https://user:password@example.com", "https://example.com/api", "https://example.com?key=x", "https://example.com#fragment", "file:///tmp"] {
            XCTAssertThrowsError(try PersonalAgentCloud.endpoint(address), address)
        }
        for address in ["https://agents.example.com", "http://127.0.0.1:8787", "http://localhost:8787"] {
            XCTAssertNoThrow(try PersonalAgentCloud.endpoint(address), address)
        }
    }

    func testCloudConnectionIsSeparateFromLocalStateAndRetriesUseSameID() async throws {
        let fixture = CloudHTTPFixture()
        CloudURLProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudURLProtocol.self]
        let cloud = PersonalAgentCloud(configuration: configuration)
        defer { cloud.suspend(); CloudURLProtocol.fixture = nil }
        let local = PersonalAgentStore(rootURL: nil)
        let original = local.archive
        let coordinator = PersonalAgentCoordinator(store: local, endpoint: { XCTFail("Cloud must not use local execution"); throw CancellationError() }, model: { "test" }, isReady: { false }, cloud: cloud)
        coordinator.drafts[original.agents[0].id] = "Local draft"
        try await cloud.connect(address: "https://agents.example.test", token: String(repeating: "a", count: 40))
        cloud.suspend()
        XCTAssertNil(coordinator.drafts[original.agents[0].id])
        XCTAssertTrue(cloud.connected)
        XCTAssertNotEqual(coordinator.archive.agents[0].id, original.agents[0].id)
        let agent = cloud.archive.agents[0]
        fixture.failSendOnce = true
        do { try await cloud.send("Check", agentID: agent.id, routineID: nil); XCTFail("Must report uncertain delivery") }
        catch {}
        try await cloud.send("Check", agentID: agent.id, routineID: nil)
        let sent = fixture.actions.filter { $0["action"] as? String == "send" }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["id"] as? String, sent[1]["id"] as? String)
        XCTAssertEqual(local.archive, original)
        cloud.useLocal()
        XCTAssertEqual(coordinator.archive, original)
        XCTAssertEqual(coordinator.drafts[original.agents[0].id], "Local draft")
        XCTAssertTrue(cloud.requests.isEmpty)
    }

    func testOlderResponsesCannotReplaceNewerStateAndIdentityChangesRequireReconnect() async throws {
        let fixture = CloudHTTPFixture()
        CloudURLProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudURLProtocol.self]
        let cloud = PersonalAgentCloud(configuration: configuration)
        defer { cloud.suspend(); CloudURLProtocol.fixture = nil }
        try await cloud.connect(address: "https://agents.example.test", token: String(repeating: "a", count: 40))
        cloud.suspend()
        fixture.revision = 5; fixture.name = "Newest"
        await cloud.refresh()
        XCTAssertEqual(cloud.archive.agents[0].name, "Newest")
        fixture.revision = 2; fixture.name = "Stale"
        await cloud.refresh()
        XCTAssertEqual(cloud.archive.agents[0].name, "Newest")
        fixture.serviceID = "replacement"
        await cloud.refresh()
        XCTAssertFalse(cloud.connected)
        XCTAssertEqual(cloud.archive.agents[0].name, "Newest")
        XCTAssertNotNil(cloud.error)
        do { try await cloud.action(["action": "delete", "collection": "agents", "id": cloud.archive.agents[0].id.uuidString]); XCTFail("Identity change must block mutations") }
        catch {}
        XCTAssertTrue(fixture.actions.isEmpty)
    }
}

private final class CloudHTTPFixture: @unchecked Sendable {
    var revision = 1
    var name = "Server agent"
    var serviceID = "test-service"
    var failSendOnce = false
    var actions: [[String: Any]] = []
    private var archive = PersonalAgentArchive()
    private let lock = NSLock()

    func response(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 40))
        if request.httpMethod == "POST" {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let action = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            actions.append(action)
            if action["action"] as? String == "send", failSendOnce {
                failSendOnce = false
                throw URLError(.timedOut)
            }
        }
        archive.agents[0].name = name
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let object = try JSONSerialization.jsonObject(with: encoder.encode(archive))
        return (200, try JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "serviceID": serviceID, "revision": revision, "archive": object, "interactions": []]))
    }
}

private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: CloudHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "agents.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let fixture = try XCTUnwrap(Self.fixture)
            let (status, data) = try fixture.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
