import XCTest
import MarrCore
@testable import Marr

@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    func testProjectTaskAndConversationDraftsSurviveRestartWithAttachmentsAndBindings() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ComposerDraftStore(rootURL: root)
        let projectA = UUID(), projectB = UUID(), taskA = UUID(), taskB = UUID()
        let keys: [ComposerDraftKey] = [
            .work(workspaceID: projectA, taskID: taskA),
            .work(workspaceID: projectA, taskID: taskB),
            .work(workspaceID: projectB, taskID: nil),
            .conversation(UUID())
        ]
        let attachment = ConversationImageAsset(data: Data("private draft bytes".utf8),
                                                mimeType: "text/plain", fileName: "../../notes.txt")
        let binding = ComposerMentionBinding(kind: .integration, name: "Documents",
                                             path: "plugin://docs@example", reference: "Documents")
        for (index, key) in keys.enumerated() {
            XCTAssertTrue(store.save(ComposerDraft(text: "Draft \(index)", selection: NSRange(location: 2, length: 3),
                attachments: index == 0 ? [attachment] : [], bindings: index == 0 ? [binding] : []), for: key))
        }
        let restored = ComposerDraftStore(rootURL: root)
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(restored.draft(for: key).text, "Draft \(index)")
            XCTAssertEqual(restored.draft(for: key).selection, NSRange(location: 2, length: 3))
        }
        XCTAssertEqual(restored.draft(for: keys[0]).attachments, [attachment])
        XCTAssertEqual(restored.draft(for: keys[0]).bindings, [binding])
        let manifest = try String(contentsOf: root.appendingPathComponent("drafts.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains(attachment.data.base64EncodedString()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/\(attachment.id.uuidString)").path))
    }

    func testNewTaskDraftMigratesOnceAndKeepsLocalIdentityBeforeThreadAcknowledgement() throws {
        let fixture = try runtimeFixture()
        defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let sourceKey = runtime.composerDraftKey
        let attachment = ConversationImageAsset(data: Data("draft".utf8), mimeType: "text/plain", fileName: "draft.txt")
        runtime.composerDraftStore.save(ComposerDraft(text: "Send this", attachments: [attachment]), for: sourceKey)
        XCTAssertTrue(runtime.submit(prompt: "Send this", images: [attachment]))
        let taskID = try XCTUnwrap(runtime.composerDraftKey.taskID)
        XCTAssertNil(runtime.workbench.selectedTask?.threadID)
        XCTAssertTrue(runtime.composerDraftStore.draft(for: sourceKey).isEmpty)
        let pending = try XCTUnwrap(ComposerDraftStore(rootURL: fixture.draftRoot).recoveries.first)
        XCTAssertEqual(pending.taskID, taskID)
        XCTAssertEqual(pending.attachments, [attachment])
        XCTAssertNil(pending.threadID)

        let request = try XCTUnwrap(fixture.messages.values.last { $0["method"] as? String == "thread/start" })
        runtime.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "error": ["message": "Offline"]])
        let failed = try XCTUnwrap(runtime.recoverableDrafts.first)
        XCTAssertEqual(failed.taskID, taskID)
        XCTAssertTrue(runtime.restoreRecoveredDraft(failed))
        XCTAssertEqual(runtime.composerDraftKey.taskID, taskID)
        XCTAssertEqual(runtime.composerDraftStore.draft(for: runtime.composerDraftKey).text, "Send this")
        XCTAssertTrue(ComposerDraftStore(rootURL: fixture.draftRoot).recoveries.isEmpty)
    }

    func testRecoveryReturnsToOriginalTaskWithoutChangingOtherDraft() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ComposerDraftTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workbench = WorkbenchStore(defaults: defaults)
        let projectA = workbench.upsertWorkspace(url: root.appendingPathComponent("A"), bookmark: Data())
        let taskA = workbench.createTask(workspaceID: projectA.id, prompt: "Task A")
        workbench.updateTask(id: taskA.id, threadID: "thread-A", state: .failed)
        let projectB = workbench.upsertWorkspace(url: root.appendingPathComponent("B"), bookmark: Data())
        let taskB = workbench.createTask(workspaceID: projectB.id, prompt: "Task B")
        workbench.updateTask(id: taskB.id, threadID: "thread-B", state: .completed)
        let draftRoot = root.appendingPathComponent("Drafts")
        let store = ComposerDraftStore(rootURL: draftRoot)
        let keyA = ComposerDraftKey.work(workspaceID: projectA.id, taskID: taskA.id)
        let keyB = ComposerDraftKey.work(workspaceID: projectB.id, taskID: taskB.id)
        store.save(ComposerDraft(text: "Unsent A"), for: keyA)
        store.save(ComposerDraft(text: "Unsent B"), for: keyB)
        let attachment = ConversationImageAsset(data: Data("A file".utf8), mimeType: "text/plain", fileName: "a.txt")
        store.retainRecovery(CodexSubmissionDraft(prompt: "Failed A", attachments: [attachment],
            workspaceID: projectA.id, taskID: taskA.id, threadID: "thread-A", error: "Offline"))
        let messages = Messages()
        let runtime = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { messages.values.append($0) },
            attachmentDirectory: root.appendingPathComponent("Attachments"), draftDirectory: draftRoot, codexSyncEnabled: true)
        XCTAssertEqual(runtime.composerDraftKey, keyB)
        XCTAssertTrue(runtime.restoreRecoveredDraft(try XCTUnwrap(runtime.recoverableDrafts.first)))
        XCTAssertEqual(runtime.composerDraftKey, keyA)
        XCTAssertEqual(runtime.composerDraftStore.draft(for: keyB).text, "Unsent B")
        XCTAssertEqual(runtime.composerDraftStore.draft(for: keyA).text, "Unsent A\n\nFailed A")
        XCTAssertEqual(runtime.composerDraftStore.draft(for: keyA).attachments, [attachment])
        let read = try XCTUnwrap(messages.values.last { $0["method"] as? String == "thread/read" })
        XCTAssertEqual((read["params"] as? [String: Any])?["threadId"] as? String, "thread-A")
        XCTAssertFalse(runtime.canSubmit, "The restored thread must be read before it accepts a turn")
        runtime.receiveServerMessage(["id": try XCTUnwrap(read["id"]), "result": [
            "thread": ["id": "thread-A", "cwd": projectA.path, "status": ["type": "idle"], "turns": []]
        ]])
        XCTAssertTrue(runtime.canSubmit, "Recovery must complete the normal read lifecycle without a manual refresh")
        let restarted = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { _ in },
            attachmentDirectory: root.appendingPathComponent("Attachments"), draftDirectory: draftRoot, codexSyncEnabled: true)
        XCTAssertEqual(restarted.composerDraftKey, keyA)
        XCTAssertEqual(restarted.composerDraftStore.draft(for: keyB).text, "Unsent B")
    }

    func testNewThreadCommandFailureRecoversIntoItsOriginalLocalTask() throws {
        for command in ["/review custom Inspect the layout", "/goal Finish the layout"] {
            let fixture = try runtimeFixture()
            defer { fixture.cleanup() }
            XCTAssertTrue(fixture.runtime.executeSlashCommand(command))
            let taskID = try XCTUnwrap(fixture.runtime.composerDraftKey.taskID)
            let retained = try XCTUnwrap(ComposerDraftStore(rootURL: fixture.draftRoot).recoveries.first)
            XCTAssertEqual(retained.taskID, taskID)
            XCTAssertNil(retained.threadID)
            let request = try fixture.request("thread/start")
            fixture.runtime.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "error": ["message": "Offline"]])
            fixture.runtime.startNewTask()
            let recovery = try XCTUnwrap(fixture.runtime.recoverableDrafts.first)
            XCTAssertTrue(fixture.runtime.restoreRecoveredDraft(recovery))
            XCTAssertEqual(fixture.runtime.composerDraftKey.taskID, taskID)
            XCTAssertEqual(fixture.runtime.composerDraftStore.draft(for: fixture.runtime.composerDraftKey).text, command)
            XCTAssertEqual(fixture.runtime.workbench.tasks.count, 1, "Recovery must not create another task")
        }
    }

    func testAcceptedCommandNotificationsClearDurableRecoveryBeforeRPCResponse() throws {
        for notification in ["turn/started", "turn/completed"] {
            let fixture = try runtimeFixture()
            defer { fixture.cleanup() }
            XCTAssertTrue(fixture.runtime.executeSlashCommand("/review custom Inspect the layout"))
            try fixture.respond("thread/start", [
                "thread": ["id": "thread-command", "cwd": fixture.root.path, "status": ["type": "idle"], "turns": []]
            ])
            XCTAssertEqual(ComposerDraftStore(rootURL: fixture.draftRoot).recoveries.count, 1)
            let request = try fixture.request("review/start")
            fixture.runtime.receiveServerMessage(["method": notification, "params": [
                "threadId": "thread-command", "turn": ["id": "review-turn",
                    "status": notification == "turn/completed" ? "completed" : "inProgress"]
            ]])
            XCTAssertTrue(ComposerDraftStore(rootURL: fixture.draftRoot).recoveries.isEmpty,
                "The acceptance event must clean recovery even if its RPC response is lost")
            fixture.runtime.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "result": [
                "reviewThreadId": "thread-command", "turn": ["id": "review-turn"]
            ]])
            let restarted = RuntimeWorkspaceController(defaults: fixture.defaults, outboundMessage: { _ in },
                attachmentDirectory: fixture.root.appendingPathComponent("Attachments"), draftDirectory: fixture.draftRoot, codexSyncEnabled: true)
            XCTAssertTrue(restarted.recoverableDrafts.isEmpty)
        }
    }

    func testMissingRecoveryOriginIsRetainedWithoutChangingTask() throws {
        let fixture = try runtimeFixture()
        defer { fixture.cleanup() }
        let original = fixture.runtime.composerDraftKey
        let recovery = CodexSubmissionDraft(prompt: "Keep me", attachments: [],
            workspaceID: original.workspaceID, taskID: UUID(), threadID: "missing")
        fixture.runtime.composerDraftStore.retainRecovery(recovery)
        XCTAssertFalse(fixture.runtime.restoreRecoveredDraft(recovery))
        XCTAssertEqual(fixture.runtime.composerDraftKey, original)
        XCTAssertEqual(ComposerDraftStore(rootURL: fixture.draftRoot).recoveries.map(\.id), [recovery.id])
    }

    func testRetryingUnchangedDraftAfterDiskFailureWritesIt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("Blocked")
        try Data("file".utf8).write(to: blocked)
        let store = ComposerDraftStore(rootURL: blocked)
        let key = ComposerDraftKey.conversation(UUID())
        let draft = ComposerDraft(text: "Do not lose this")
        XCTAssertFalse(store.save(draft, for: key))
        XCTAssertNotNil(store.lastErrorMessage)
        try FileManager.default.removeItem(at: blocked)
        XCTAssertTrue(store.save(draft, for: key))
        XCTAssertNil(store.lastErrorMessage)
        XCTAssertEqual(ComposerDraftStore(rootURL: blocked).draft(for: key).text, draft.text)
    }

    func testRemovingBoundContextOnlyRemovesMatchingTokens() {
        let binding = ComposerMentionBinding(kind: .file, name: "Notes.md", path: "/project/Notes.md", reference: "/project/Notes.md")
        let text = "Read @Notes.md and @Other.md"
        let ranges = binding.ranges(in: text, workspaceURL: URL(fileURLWithPath: "/project"))
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first.map { (text as NSString).substring(with: $0) }, "@Notes.md")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ComposerDrafts-\(UUID())", isDirectory: true)
    }

    private final class Messages { var values: [[String: Any]] = [] }
    @MainActor
    private struct Fixture {
        let root: URL
        let draftRoot: URL
        let suite: String
        let defaults: UserDefaults
        let runtime: RuntimeWorkspaceController
        let messages: Messages
        func request(_ method: String) throws -> [String: Any] {
            try XCTUnwrap(messages.values.last { $0["method"] as? String == method })
        }
        func respond(_ method: String, _ result: [String: Any]) throws {
            runtime.receiveServerMessage(["id": try XCTUnwrap(try request(method)["id"]), "result": result])
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func runtimeFixture() throws -> Fixture {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ComposerDraftTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workbench = WorkbenchStore(defaults: defaults)
        _ = workbench.upsertWorkspace(url: root, bookmark: Data())
        let messages = Messages()
        let drafts = root.appendingPathComponent("Drafts")
        let runtime = RuntimeWorkspaceController(defaults: defaults,
            outboundMessage: { messages.values.append($0) },
            attachmentDirectory: root.appendingPathComponent("Attachments"), draftDirectory: drafts, codexSyncEnabled: true)
        return Fixture(root: root, draftRoot: drafts, suite: suite, defaults: defaults, runtime: runtime, messages: messages)
    }
}
