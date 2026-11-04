import Foundation
import MarrCore
import XCTest
import Combine
@testable import Marr

@MainActor
final class CodexWorkspaceTests: XCTestCase {
    func testCodexSyncDefaultsOffAndBlocksDiscoveryAndRPC() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", restoredState: .running, syncEnabled: nil)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        XCTAssertFalse(controller.codexSyncEnabled)
        XCTAssertFalse(controller.isRemoteTaskActive)
        XCTAssertNil(controller.codexCLIURL)
        fixture.enableHistorySync()
        controller.performHistorySyncTick()
        controller.refreshModelsIfNeeded()
        controller.refreshModels()
        controller.refreshCapabilities()
        controller.refreshAccount()
        controller.refreshConfiguration()
        controller.refreshRateLimits()
        controller.loadTaskHistory()
        controller.loadAllTaskHistory()
        controller.loadArchivedTaskHistory()
        controller.refreshSelectedTask()
        controller.startAppServerInBackground()
        XCTAssertTrue(fixture.transport.messages.isEmpty)
        XCTAssertFalse(controller.isLoadingModels)
        XCTAssertFalse(controller.isLoadingTaskHistory)
        XCTAssertFalse(controller.desktopSidebarSyncAvailable)
        XCTAssertEqual(fixture.defaults.data(forKey: "codex.workspace.bookmark"), Data())
    }

    func testDisabledCodexRejectsMutationsWithoutChangingCachedHistory() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", syncEnabled: false)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let task = try XCTUnwrap(controller.workbench.selectedTask)
        let tasks = controller.workbench.tasks
        XCTAssertFalse(controller.submit(prompt: "Should stay local", images: []))
        XCTAssertFalse(controller.renameSelectedTask("Changed"))
        XCTAssertFalse(controller.executeSlashCommand("/compact"))
        XCTAssertFalse(controller.setConfigurationValue("model", value: "changed"))
        controller.toggleTaskPinned(task)
        controller.archiveTask(task)
        controller.unarchiveTask(task)
        controller.startAccountLogin()
        controller.logoutAccount()
        XCTAssertEqual(controller.workbench.tasks, tasks)
        XCTAssertTrue(controller.recoverableDrafts.isEmpty)
        XCTAssertTrue(fixture.transport.messages.isEmpty)
    }

    func testTurningCodexSyncOffStopsRequestsAndKeepsImportedHistoryAndPreferences() throws {
        let cached = [WorkActivity(kind: .message, title: "Codex", detail: "Saved answer")]
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", cachedActivities: cached)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.refreshSkills()
        let previousCount = fixture.transport.messages.count
        let taskID = controller.workbench.selectedTaskID
        let bookmark = fixture.defaults.data(forKey: "codex.workspace.bookmark")
        XCTAssertTrue(controller.setCodexSyncEnabled(false))
        fixture.enableHistorySync()
        controller.performHistorySyncTick()
        controller.refreshModelsIfNeeded()
        controller.refreshSelectedTask()
        fixture.notify("turn/started", ["turn": ["id": "late-turn"]])
        controller.handleTransportFailure("Late socket closure")
        XCTAssertFalse(controller.codexSyncEnabled)
        XCTAssertFalse(fixture.defaults.bool(forKey: RuntimeWorkspaceController.codexSyncEnabledKey))
        XCTAssertEqual(fixture.transport.messages.count, previousCount)
        XCTAssertEqual(controller.workbench.selectedTaskID, taskID)
        XCTAssertEqual(controller.activities, cached)
        XCTAssertEqual(fixture.defaults.data(forKey: "codex.workspace.bookmark"), bookmark)
        XCTAssertFalse(controller.isRunning)
        XCTAssertFalse(controller.isRemoteTaskActive)
        XCTAssertTrue(controller.statusMessage.contains("Enable Sync") || controller.statusMessage.contains("sync is off"))
        XCTAssertTrue(controller.setCodexSyncEnabled(true))
        XCTAssertTrue(fixture.defaults.bool(forKey: RuntimeWorkspaceController.codexSyncEnabledKey))
        controller.refreshSkills()
        XCTAssertGreaterThan(fixture.transport.messages.count, previousCount)
    }

    func testTurningCodexSyncOffRefusesActiveTaskThenSucceedsWhenCompleted() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        XCTAssertFalse(fixture.controller.setCodexSyncEnabled(false))
        XCTAssertTrue(fixture.controller.codexSyncEnabled)
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.codexSyncStatusMessage.contains("Finish or stop"))
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.setCodexSyncEnabled(false))
        XCTAssertFalse(fixture.controller.codexSyncEnabled)
    }

    func testTurningCodexSyncOffRefusesUnacknowledgedSidebarMutation() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let task = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        fixture.controller.toggleTaskPinned(task)
        XCTAssertFalse(fixture.controller.setCodexSyncEnabled(false))
        XCTAssertTrue(fixture.controller.codexSyncEnabled)
        try fixture.respond("thread/section/move", [:])
        XCTAssertTrue(fixture.controller.setCodexSyncEnabled(false))
    }

    func testSwitchingHistoryDisplaysCachedAnswerBeforeNetworkReadCompletes() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
        let task = fixture.controller.workbench.upsertRemoteTask(workspaceID: workspaceID,
            threadID: "cached-next", title: "Next", state: .completed, statusMessage: "Saved",
            createdAt: Date(), updatedAt: Date())
        let cached = [WorkActivity(kind: .user, title: "You", detail: "Saved question"),
                      WorkActivity(kind: .message, title: "Codex", detail: "Cached answer")]
        fixture.controller.workbench.updateTask(id: task.id, latestAgentMessage: "Cached answer", activities: cached)
        XCTAssertTrue(fixture.controller.selectTask(task))
        XCTAssertEqual(fixture.controller.activities, cached)
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Cached answer")
        XCTAssertTrue(fixture.controller.isReadingSelectedTask, "Cached content is usable while verification is still pending")
        XCTAssertEqual(try fixture.params("thread/read")["threadId"] as? String, "cached-next")
    }

    func testSelectingSavedHistoryDoesNotSynchronouslyRewriteArchive() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let task = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        fixture.controller.flushPendingTaskSnapshot()
        let writes = fixture.controller.workbench.persistenceDiagnostics.writes
        XCTAssertTrue(fixture.controller.selectTask(task))
        XCTAssertEqual(fixture.controller.workbench.persistenceDiagnostics.writes, writes)
        XCTAssertEqual(fixture.controller.workbench.selectedTaskID, task.id)
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 1)
        fixture.controller.flushPendingTaskSnapshot()
        XCTAssertGreaterThan(fixture.controller.workbench.persistenceDiagnostics.writes, writes)
    }

    func testOversizedHistoryStopsAutomaticReadRetriesButAllowsExplicitRetry() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.controller.refreshSelectedTask()
        fixture.controller.handleTransportFailure("Receive limit exceeded", retryable: false)
        fixture.enableHistorySync()
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 1)
        XCTAssertFalse(fixture.controller.activities.contains { $0.kind == .error })
        fixture.controller.refreshSelectedTask()
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 2)
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testHistoryTransportFailureKeepsTranscriptAndDoesNotCreateFailedTaskEvents() throws {
        let cached = [WorkActivity(kind: .user, title: "You", detail: "Saved prompt"),
                      WorkActivity(kind: .message, title: "Codex", detail: "Saved answer")]
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", cachedActivities: cached)
        defer { fixture.cleanUp() }
        for _ in 0..<3 {
            fixture.controller.refreshSelectedTask()
            XCTAssertTrue(fixture.controller.isReadingSelectedTask)
            fixture.controller.handleTransportFailure("Message too long")
            XCTAssertEqual(fixture.controller.activities, cached)
            XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .completed)
            XCTAssertEqual(fixture.controller.capabilityErrors["thread/read"], "Message too long")
            XCTAssertFalse(fixture.controller.isReconcilingConnection)
        }
        fixture.controller.refreshSelectedTask()
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])
        XCTAssertNil(fixture.controller.capabilityErrors["thread/read"])
        XCTAssertFalse(fixture.controller.activities.contains { $0.kind == .error })
    }

    func testBackgroundReadFailureOnExistingConnectionDoesNotAppendTaskError() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", restoredState: .running)
        defer { fixture.cleanUp() }
        fixture.controller.refreshSelectedTask() // Establish a foreground connection first.
        var active = fixture.thread()
        active["status"] = ["type": "active"]
        active["turns"] = [["id": "remote-turn", "status": "inProgress", "items": []]]
        try fixture.respond("thread/read", ["thread": active])
        fixture.enableHistorySync()
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 2)
        fixture.controller.handleTransportFailure("Message too long")
        XCTAssertFalse(fixture.controller.activities.contains { $0.kind == .error })
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .running)
        let requestCount = fixture.transport.messages.count
        fixture.controller.performHistorySyncTick()
        XCTAssertEqual(fixture.transport.messages.count, requestCount, "A failed poll must back off")
    }

    func testLongHistoryPublishesOnceAndPreservesStableItemIdentityAcrossRefresh() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        var thread = fixture.completedThread()
        thread["turns"] = (0..<200).map { index in
            ["id": "turn-\(index)", "status": "completed", "items": [
                ["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Prompt \(index)"]]],
                ["id": "tool", "type": "commandExecution", "command": "echo", "exitCode": 0, "aggregatedOutput": "output"],
                ["id": "answer", "type": "agentMessage", "text": "Answer \(index)"]
            ]] as [String: Any]
        }
        fixture.controller.refreshSelectedTask()
        var publicationSizes: [Int] = []
        let observation = fixture.controller.$activities.dropFirst().sink { publicationSizes.append($0.count) }
        defer { observation.cancel() }
        try fixture.respond("thread/read", ["thread": thread])
        XCTAssertEqual(publicationSizes, [600])
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Answer 199")
        let IDs = fixture.controller.activities.map(\.id)
        publicationSizes = []
        fixture.controller.refreshSelectedTask()
        try fixture.respond("thread/read", ["thread": thread])
        XCTAssertEqual(publicationSizes, [600])
        XCTAssertEqual(fixture.controller.activities.map(\.id), IDs)
    }

    func testActiveScrollingDefersBackgroundPollingUntilScrollEnds() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.controller.setHistorySyncUserScrolling(true)
        fixture.enableHistorySync()
        XCTAssertTrue(fixture.transport.messages.isEmpty)
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(30))
        XCTAssertTrue(fixture.transport.messages.isEmpty)
        fixture.controller.setHistorySyncUserScrolling(false)
        fixture.controller.performHistorySyncTick()
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 1)
    }

    func testNewConversationCarriesCanonicalProjectAndImportsAcknowledgedMembership() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.workbench.importProjects([["id": "shared-project", "name": "Shared",
            "roots": [["path": fixture.directory.path]]]])
        XCTAssertTrue(fixture.controller.submit(prompt: "Begin", images: []))
        XCTAssertEqual(try fixture.params("thread/start")["projectId"] as? String, "shared-project")
        var thread = fixture.thread()
        thread["projectId"] = "shared-project"
        thread["section"] = NSNull()
        try fixture.respond("thread/start", ["thread": thread])
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.projectID, "shared-project")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.hasCanonicalProject, true)
        XCTAssertEqual(fixture.controller.workspaceURL?.path, fixture.directory.path)
    }

    func testSidebarPinWaitsForServerAcknowledgementAndFailedUnpinKeepsState() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let task = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        fixture.controller.toggleTaskPinned(task)
        XCTAssertEqual(try fixture.params("thread/section/move")["sectionId"] as? String, WorkbenchStore.pinnedSectionID)
        XCTAssertFalse(fixture.controller.workbench.isTaskPinned(task.id))
        fixture.controller.toggleTaskPinned(task)
        XCTAssertEqual(fixture.transport.requests("thread/section/move").count, 1)
        try fixture.respond("thread/section/move", [:])
        XCTAssertTrue(fixture.controller.workbench.isTaskPinned(task.id))
        fixture.controller.toggleTaskPinned(task)
        XCTAssertTrue(try fixture.params("thread/section/move")["sectionId"] is NSNull)
        try fixture.fail("thread/section/move", "Unsupported method")
        XCTAssertTrue(fixture.controller.workbench.isTaskPinned(task.id))
        XCTAssertNotNil(fixture.controller.capabilityErrors["thread/section/move"])
        fixture.controller.toggleTaskPinned(task)
        try fixture.respond("thread/section/move", [:])
        XCTAssertFalse(fixture.controller.workbench.isTaskPinned(task.id))
    }

    func testSidebarProjectMovePreservesCwdAndSelectionAndNullClearsMembership() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let task = try XCTUnwrap(controller.workbench.selectedTask)
        controller.workbench.importProjects([["id": "other-project", "name": "Other", "roots": [["path": "/tmp/another-project"]]]])
        let project = try XCTUnwrap(controller.workbench.workspaces.first { $0.projectID == "other-project" })
        controller.assignTask(task, to: project)
        XCTAssertNil(controller.workbench.selectedTask?.projectID)
        XCTAssertEqual(try fixture.params("thread/metadata/update")["projectId"] as? String, "other-project")
        try fixture.respond("thread/metadata/update", [:])
        XCTAssertEqual(controller.workbench.selectedTask?.projectID, "other-project")
        XCTAssertEqual(controller.workbench.selectedTask?.workspaceID, task.workspaceID)
        XCTAssertEqual(controller.workspaceURL?.path, fixture.directory.path)
        controller.assignTask(task, to: nil)
        try fixture.respond("thread/metadata/update", [:])
        XCTAssertNil(controller.workbench.selectedTask?.projectID)
        XCTAssertEqual(controller.workbench.selectedTaskID, task.id)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testHistoryRefreshImportsExternalPinsAndProjectMembership() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        try fixture.respond("project/list", ["data": [["id": "project-a", "name": "Shared", "roots": [["path": "/tmp/shared"]]]]])
        fixture.controller.performHistorySyncTick()
        var remote = fixture.thread(id: "remote", cwd: "/tmp/shared-worktree")
        remote["projectId"] = "project-a"
        remote["section"] = ["id": WorkbenchStore.pinnedSectionID, "name": "Pinned"]
        try fixture.respond("thread/list", ["data": [remote]])
        let task = try XCTUnwrap(fixture.controller.workbench.tasks.first)
        XCTAssertTrue(fixture.controller.workbench.isTaskPinned(task.id))
        XCTAssertEqual(task.projectID, "project-a")
        XCTAssertEqual(fixture.controller.sidebarWorkspaces.map(\.name), ["Shared"])
        XCTAssertNil(fixture.controller.workbench.selectedTaskID)
    }

    func testHistorySelectionSupersedesPendingReadsAndRejectsLateResponses() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", restoredState: .running)
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let first = try XCTUnwrap(controller.workbench.selectedTask)
        XCTAssertFalse(controller.canSubmit)
        XCTAssertNil(controller.historySelectionBlockReason)
        // A restored selection still needs a complete read when clicked.
        XCTAssertTrue(controller.selectTask(first))
        let oldRead = try fixture.request("thread/read")
        let second = controller.workbench.upsertRemoteTask(workspaceID: first.workspaceID,
            threadID: "thread-2", title: "Second conversation", state: .completed,
            statusMessage: "Done", createdAt: Date(), updatedAt: Date())
        XCTAssertTrue(controller.isReadingSelectedTask)
        XCTAssertNil(controller.historySelectionBlockReason)
        XCTAssertTrue(controller.selectTask(second))
        XCTAssertEqual(controller.workbench.selectedTaskID, second.id)
        XCTAssertEqual(try fixture.params("thread/read")["threadId"] as? String, "thread-2")
        controller.receiveServerMessage(["id": try XCTUnwrap(oldRead["id"]),
            "result": ["thread": fixture.completedThread()]])
        XCTAssertEqual(controller.workbench.selectedTaskID, second.id)
        XCTAssertTrue(controller.isReadingSelectedTask)
        try fixture.respond("thread/read", ["thread": fixture.thread(id: "thread-2")])
        XCTAssertFalse(controller.isReadingSelectedTask)
        XCTAssertEqual(controller.workbench.selectedTask?.threadID, "thread-2")
        XCTAssertTrue(controller.canSubmit)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testHistorySelectionInterruptsCatalogRefreshAndRetriesFailedRead() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let task = try XCTUnwrap(controller.workbench.selectedTask)
        controller.loadAllTaskHistory()
        XCTAssertTrue(controller.isLoadingTaskHistory)
        XCTAssertNil(controller.historySelectionBlockReason)
        XCTAssertTrue(controller.selectTask(task))
        XCTAssertFalse(controller.isLoadingTaskHistory)
        XCTAssertTrue(controller.isReadingSelectedTask)
        let reads = fixture.transport.requests("thread/read").count
        // Clicking the same loading row acknowledges selection without restarting it.
        XCTAssertTrue(controller.selectTask(task))
        XCTAssertEqual(fixture.transport.requests("thread/read").count, reads)
        try fixture.fail("thread/read", "Temporary read failure")
        XCTAssertNotNil(controller.capabilityErrors["thread/read"])
        XCTAssertTrue(controller.selectTask(task))
        XCTAssertNil(controller.capabilityErrors["thread/read"])
        XCTAssertEqual(fixture.transport.requests("thread/read").count, reads + 1)
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])
        XCTAssertEqual(controller.workbench.selectedTaskID, task.id)
        XCTAssertFalse(controller.isReadingSelectedTask)
    }

    func testHistorySelectionCanLeaveRemoteUnknownStatusButProtectsLocalTurn() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        let first = try XCTUnwrap(controller.workbench.selectedTask)
        let second = controller.workbench.upsertRemoteTask(workspaceID: first.workspaceID,
            threadID: "thread-2", title: "Second conversation", state: .completed,
            statusMessage: "Done", createdAt: Date(), updatedAt: Date())
        controller.selectTask(first)
        var unknown = fixture.thread()
        unknown["status"] = ["type": "notLoaded"]
        unknown["turns"] = [["id": "legacy", "status": "interrupted", "items": []]]
        try fixture.respond("thread/read", ["thread": unknown])
        XCTAssertTrue(controller.isTaskStatusUncertain)
        XCTAssertFalse(controller.canSubmit)
        XCTAssertNil(controller.historySelectionBlockReason)
        XCTAssertTrue(controller.selectTask(second))
        try fixture.respond("thread/read", ["thread": fixture.thread(id: "thread-2")])
        controller.startNewTask()
        try fixture.startTurn()
        XCTAssertNotNil(controller.historySelectionBlockReason)
        let running = controller.workbench.selectedTaskID
        XCTAssertFalse(controller.selectTask(second))
        XCTAssertEqual(controller.workbench.selectedTaskID, running)
    }

    func testExplicitSavedHistoryResumeOnlyLoadsTheSelectedThreadAndPreservesTheDraft() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        var thread = fixture.thread()
        thread["status"] = ["type": "notLoaded"]
        thread["turns"] = [["id": "legacy-turn", "status": "interrupted", "items": []]]
        try fixture.respond("thread/read", ["thread": thread])
        XCTAssertTrue(fixture.controller.canResumeSavedHistory)
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty, "Automatic sync remains strictly read-only")
        let key = fixture.controller.composerDraftKey
        fixture.controller.composerDraftStore.save(ComposerDraft(text: "Do not send this"), for: key)
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(4))
        let oldPoll = try fixture.request("thread/read")
        fixture.controller.resumeSavedHistory()
        fixture.controller.resumeSavedHistory()
        XCTAssertTrue(fixture.controller.isResumingSavedHistory)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.transport.requests("thread/resume").count, 1)
        XCTAssertEqual(try fixture.params("thread/resume")["threadId"] as? String, "thread-1")
        XCTAssertNil(try fixture.params("thread/resume")["input"])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldPoll["id"]), "result": ["thread": fixture.completedThread()]])
        XCTAssertTrue(fixture.controller.isResumingSavedHistory)
        thread["status"] = ["type": "idle"]
        try fixture.respond("thread/resume", ["thread": thread])
        XCTAssertFalse(fixture.controller.isResumingSavedHistory)
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .interrupted)
        XCTAssertEqual(fixture.controller.composerDraftStore.draft(for: key).text, "Do not send this")
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/steer").isEmpty)
    }

    func testExplicitSavedHistoryResumeFailureRetainsUnknownAndActiveResultRetainsSendLock() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        var thread = fixture.thread()
        thread["status"] = ["type": "notLoaded"]
        thread["turns"] = [["id": "legacy-turn", "status": "interrupted", "items": []]]
        try fixture.respond("thread/read", ["thread": thread])
        fixture.controller.resumeSavedHistory()
        try fixture.fail("thread/resume", "Unable to load")
        XCTAssertFalse(fixture.controller.isResumingSavedHistory)
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertTrue(fixture.controller.canResumeSavedHistory)
        XCTAssertNotNil(fixture.controller.capabilityErrors["thread/resume"])
        fixture.controller.resumeSavedHistory()
        XCTAssertNil(fixture.controller.capabilityErrors["thread/resume"])
        thread["status"] = ["type": "active"]
        thread["turns"] = [["id": "external", "status": "inProgress", "items": []]]
        try fixture.respond("thread/resume", ["thread": thread])
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertFalse(fixture.controller.canResumeSavedHistory)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testExplicitSavedHistoryResumeRejectsUnconfirmedLocalDraftsAndLateSelectionResponses() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        var thread = fixture.thread()
        thread["status"] = ["type": "notLoaded"]
        thread["turns"] = [["id": "legacy-turn", "status": "interrupted", "items": []]]
        try fixture.respond("thread/read", ["thread": thread])
        let draft = CodexSubmissionDraft(prompt: "Unconfirmed", attachments: [],
            workspaceID: fixture.controller.workbench.selectedWorkspaceID,
            taskID: fixture.controller.workbench.selectedTaskID, threadID: "thread-1", bindings: [])
        fixture.controller.composerDraftStore.retainRecovery(draft)
        XCTAssertFalse(fixture.controller.canResumeSavedHistory)
        fixture.controller.resumeSavedHistory()
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        fixture.controller.composerDraftStore.removeRecovery(draft.id)
        fixture.controller.resumeSavedHistory()
        let request = try fixture.request("thread/resume")
        fixture.controller.startNewTask()
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "result": ["thread": fixture.completedThread()]])
        XCTAssertFalse(fixture.controller.isResumingSavedHistory)
        XCTAssertNil(fixture.controller.workbench.selectedTaskID)
        XCTAssertTrue(fixture.controller.activities.isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testHistorySyncInitializationIsReadOnlyAndCanUpgradeForExplicitPendingUIRequests() throws {
        for upgrade in [false, true] {
            let fixture = try WorkspaceFixture(initializeTransport: true)
            defer { fixture.cleanUp() }
            fixture.enableHistorySync()
            XCTAssertEqual(fixture.transport.requests("initialize").count, 1)
            if upgrade {
                fixture.controller.refreshModels()
                fixture.controller.refreshSkills()
                fixture.controller.refreshAccount()
                XCTAssertEqual(fixture.transport.requests("initialize").count, 1)
            }
            try fixture.respond("initialize", ["userAgent": "Local test runtime"])
            if upgrade {
                XCTAssertEqual(fixture.transport.requests("model/list").count, 1)
                XCTAssertEqual(fixture.transport.requests("skills/list").count, 1)
                XCTAssertEqual(fixture.transport.requests("account/read").count, 1)
                try fixture.respond("model/list", ["data": []])
                XCTAssertFalse(fixture.controller.isLoadingModels)
            } else {
                XCTAssertEqual(fixture.transport.requests("project/list").count, 1)
                XCTAssertTrue(fixture.transport.requests("model/list").isEmpty)
                XCTAssertTrue(fixture.transport.requests("skills/list").isEmpty)
            }
            XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
            XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
        }
    }

    func testHistorySyncHidingDuringInitializeDiscardsLateHandshakeAndCanReconnect() throws {
        let fixture = try WorkspaceFixture(initializeTransport: true)
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        let old = try fixture.request("initialize")
        fixture.controller.setHistorySyncVisible(false)
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(old["id"]), "result": ["userAgent": "Late"]])
        XCTAssertTrue(fixture.transport.requests("project/list").isEmpty)
        fixture.controller.setHistorySyncVisible(true)
        XCTAssertEqual(fixture.transport.requests("initialize").count, 2)
        try fixture.respond("initialize", [:])
        XCTAssertEqual(fixture.transport.requests("project/list").count, 1)
    }

    func testHistorySyncRequiresVisibleForegroundAndNeverStartsAConversation() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.performHistorySyncTick()
        fixture.controller.setHistorySyncVisible(true)
        XCTAssertTrue(fixture.transport.messages.isEmpty)
        fixture.controller.setHistorySyncAppActive(true)
        XCTAssertEqual(fixture.transport.requests("project/list").count, 1)
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(60))
        XCTAssertEqual(fixture.transport.messages.count, 1, "An unanswered request must not overlap")
        try fixture.fail("project/list", "Experimental project discovery unavailable")
        fixture.controller.performHistorySyncTick()
        let params = try fixture.params("thread/list")
        XCTAssertEqual(params["sourceKinds"] as? [String], ["cli", "vscode", "appServer", "exec", "unknown"])
        XCTAssertEqual(params["modelProviders"] as? [String], [])
        XCTAssertNil(params["cwd"])
        XCTAssertNil(params["serviceName"])
        XCTAssertNil(params["projectId"])
        XCTAssertTrue(fixture.transport.messages.allSatisfy {
            ["project/list", "thread/list", "thread/read"].contains($0["method"] as? String ?? "")
        })
        fixture.controller.setHistorySyncVisible(false)
        try fixture.respond("thread/list", ["data": [fixture.thread(id: "hidden-late")]])
        XCTAssertTrue(fixture.controller.workbench.tasks.isEmpty)
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(120))
        XCTAssertEqual(fixture.transport.requests("thread/list").count, 1)
    }

    func testHistorySyncImportsOtherDirectoriesAndArchivesWithoutChangingSelection() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let selectedWorkspace = fixture.controller.workbench.selectedWorkspaceID
        fixture.enableHistorySync()
        let other = fixture.directory.appendingPathComponent("OtherProject").path
        try fixture.respond("project/list", ["data": [["id": "project", "name": "Other", "roots": [["path": other]]]]])
        fixture.controller.performHistorySyncTick()
        var child = fixture.thread(id: "child", cwd: other)
        child["parentThreadId"] = "parent"
        try fixture.respond("thread/list", ["data": [fixture.thread(id: "vscode", cwd: other), child]])
        fixture.controller.performHistorySyncTick()
        XCTAssertEqual(try fixture.params("thread/list")["archived"] as? Bool, true)
        try fixture.respond("thread/list", ["data": [fixture.thread(id: "archive", cwd: other)]])
        XCTAssertEqual(Set(fixture.controller.workbench.tasks.compactMap(\.threadID)), ["vscode", "archive"])
        XCTAssertEqual(fixture.controller.workbench.selectedWorkspaceID, selectedWorkspace)
        XCTAssertNil(fixture.controller.workbench.selectedTaskID)
        let archived = try XCTUnwrap(fixture.controller.workbench.tasks.first { $0.threadID == "archive" })
        XCTAssertTrue(fixture.controller.workbench.isTaskArchived(archived.id))
        let imported = try XCTUnwrap(fixture.controller.workbench.tasks.first { $0.threadID == "vscode" })
        XCTAssertEqual(imported.updatedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(imported.state, .ready, "Runtime idle/notLoaded alone cannot prove a turn outcome")
    }

    func testHistorySyncReadPreservesDraftRecencyAndSkipsIdenticalSnapshots() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let key = fixture.controller.composerDraftKey
        fixture.controller.composerDraftStore.save(ComposerDraft(text: "Unsent local draft"), for: key)
        fixture.enableHistorySync()
        var thread = fixture.completedThread(runtimeStatus: "notLoaded")
        thread["turns"] = [["id": "turn-1", "status": "completed", "items": [["id": "answer", "type": "agentMessage", "text": "Updated in VSCode"]]]]
        try fixture.respond("thread/read", ["thread": thread])
        fixture.controller.flushPendingTaskSnapshot()
        let writes = fixture.controller.workbench.persistenceDiagnostics.writes
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Updated in VSCode")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.updatedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(fixture.controller.composerDraftStore.draft(for: key).text, "Unsent local draft")
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(4))
        try fixture.respond("thread/read", ["thread": thread])
        fixture.controller.flushPendingTaskSnapshot()
        XCTAssertEqual(fixture.controller.workbench.persistenceDiagnostics.writes, writes)
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testHistorySyncDropsReadAfterLocalSubmissionOrTaskChange() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        let oldRead = try fixture.request("thread/read")
        XCTAssertTrue(fixture.controller.submit(prompt: "Local turn wins", images: []))
        try fixture.respond("thread/resume", ["thread": fixture.thread()])
        try fixture.respond("turn/start", ["turn": ["id": "new-local-turn"]])
        fixture.notify("item/agentMessage/delta", ["turnId": "new-local-turn", "itemId": "live", "delta": "Live local answer"])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldRead["id"]), "result": ["thread": fixture.completedThread()]])
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Live local answer")
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(60))
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 1)
        fixture.notify("turn/completed", ["turn": ["id": "new-local-turn", "status": "completed"]])
        try fixture.respond("project/list", ["data": []])
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(60))
        let oldSelectionRead = try fixture.request("thread/read")
        fixture.controller.startNewTask()
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldSelectionRead["id"]), "result": ["thread": fixture.completedThread()]])
        XCTAssertNil(fixture.controller.workbench.selectedTaskID)
        XCTAssertTrue(fixture.controller.activities.isEmpty)
    }

    func testHistorySyncRefreshesOtherChatsDuringLocalStreamingWithoutReadingOrOverwritingTheActiveChat() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.notify("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "answer", "delta": "Streaming"])
        fixture.enableHistorySync()
        try fixture.respond("project/list", ["data": []])
        fixture.controller.performHistorySyncTick()
        var staleActive = fixture.thread()
        staleActive["name"] = "Stale remote name"
        try fixture.respond("thread/list", ["data": [staleActive, fixture.thread(id: "other-client")]])
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Streaming")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.title, "Begin")
        XCTAssertTrue(fixture.controller.workbench.tasks.contains { $0.threadID == "other-client" })
        XCTAssertTrue(fixture.transport.requests("thread/read").isEmpty)
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
    }

    func testStreamingCommentaryKeepsItsPhaseAndNeverBecomesCachedAnswer() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.notify("item/started", ["turnId": "turn-1", "item": [
            "id": "progress", "type": "agentMessage", "phase": "commentary", "text": "Checking"]])
        fixture.notify("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "progress", "delta": " files"])
        XCTAssertEqual(fixture.controller.activities.last?.detail, "Checking files")
        XCTAssertEqual(fixture.controller.activities.last?.messagePhase, "commentary")
        XCTAssertTrue(fixture.controller.latestAgentMessage.isEmpty)
        fixture.notify("item/completed", ["turnId": "turn-1", "item": [
            "id": "progress", "type": "agentMessage", "phase": "commentary", "text": "Checking files"]])
        fixture.notify("item/started", ["turnId": "turn-1", "item": [
            "id": "final", "type": "agentMessage", "phase": "final_answer", "text": ""]])
        fixture.notify("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "final", "delta": "Ready."])
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Ready.")
        XCTAssertEqual(fixture.controller.activities.last?.messagePhase, "final_answer")
    }

    func testHistorySyncTimeoutBacksOffWithoutReplayOrLosingCachedHistory() throws {
        let cached = WorkActivity(kind: .message, title: "Codex", detail: "Kept")
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", cachedActivities: [cached])
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        fixture.controller.expireServerRequest(try XCTUnwrap(try fixture.request("thread/read")["id"] as? Int))
        fixture.controller.performHistorySyncTick()
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 1)
        XCTAssertEqual(fixture.controller.activities.map(\.detail), ["Kept"])
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(4))
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 2)
        fixture.controller.setHistorySyncAppActive(false)
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])
        XCTAssertEqual(fixture.controller.activities.map(\.detail), ["Kept"])
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testHistorySyncObservedExternalTurnSurvivesForegroundCycleAndUnlocksOnlyOnDurableCompletion() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        var active = fixture.thread()
        active["status"] = ["type": "notLoaded"]
        active["turns"] = [["id": "external-turn", "status": "inProgress", "items": []]]
        try fixture.respond("thread/read", ["thread": active])
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        fixture.controller.setHistorySyncAppActive(false)
        fixture.controller.setHistorySyncAppActive(true)
        var interrupted = active
        interrupted["turns"] = [["id": "external-turn", "status": "interrupted", "items": []]]
        try fixture.respond("thread/read", ["thread": interrupted])
        XCTAssertFalse(fixture.controller.canSubmit, "Disk-only interrupted may be a projection of another client's live turn")
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(4))
        var complete = active
        complete["turns"] = [["id": "external-turn", "status": "completed", "items": []]]
        try fixture.respond("thread/read", ["thread": complete])
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.isRemoteTaskActive)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testHistorySyncRestoredRunningTaskVerifiesItsPersistedAcceptedTurn() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", restoredState: .running, lastKnownTurnID: "turn-1")
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        fixture.enableHistorySync()
        try fixture.respond("thread/read", ["thread": fixture.completedThread(runtimeStatus: "notLoaded")])
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.lastKnownTurnID, "turn-1")
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
    }

    func testAcceptedTurnIdentityPersistsBeforeAnyDeltaAndOldTaskArchivesRemainReadable() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let task = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        XCTAssertEqual(task.lastKnownTurnID, "turn-1")
        var oldJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        oldJSON.removeValue(forKey: "lastKnownTurnID")
        let migrated = try JSONDecoder().decode(SavedTask.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertNil(migrated.lastKnownTurnID)
        XCTAssertEqual(migrated.id, task.id)
        XCTAssertEqual(migrated.activities, task.activities)
    }

    func testHistorySyncDiskOnlyInterruptedWithoutCompletionTimeRemainsUnknown() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        var snapshot = fixture.thread()
        snapshot["status"] = ["type": "notLoaded"]
        snapshot["turns"] = [["id": "external", "status": "interrupted", "items": []]]
        try fixture.respond("thread/read", ["thread": snapshot])
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertFalse(fixture.controller.activities.contains { $0.title == "Codex task interrupted" })
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(4))
        snapshot["turns"] = [["id": "external", "status": "interrupted", "completedAt": 1_700_000_002, "items": []]]
        try fixture.respond("thread/read", ["thread": snapshot])
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .interrupted)
    }

    func testHistorySyncDirectoryGetsATurnAfterReadAndForeignNotificationsInvalidateIt() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.enableHistorySync()
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])
        fixture.controller.performHistorySyncTick()
        try fixture.respond("project/list", ["data": []])
        fixture.controller.performHistorySyncTick()
        try fixture.respond("thread/list", ["data": []])
        fixture.controller.performHistorySyncTick()
        try fixture.respond("thread/list", ["data": []])
        fixture.controller.performHistorySyncTick()
        XCTAssertEqual(fixture.transport.requests("project/list").count, 1)
        fixture.controller.receiveServerMessage(["method": "thread/name/updated", "params": ["threadId": "foreign-thread", "threadName": "Renamed elsewhere"]])
        fixture.controller.performHistorySyncTick()
        XCTAssertEqual(fixture.transport.requests("project/list").count, 2)
        let count = fixture.transport.messages.count
        fixture.controller.receiveServerMessage(["id": "foreign-approval", "method": "item/commandExecution/requestApproval", "params": ["threadId": "foreign-thread", "turnId": "t", "itemId": "i"]])
        XCTAssertEqual(fixture.transport.messages.count, count, "The read-only connection must not answer any approval")
        XCTAssertTrue(fixture.controller.pendingInteractions.isEmpty)
    }

    func testHistorySyncPaginationFailureKeepsExistingArchivesAndDoesNotDeleteMissingThreads() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
        let old = fixture.controller.workbench.upsertRemoteTask(workspaceID: workspaceID, threadID: "old", title: "Old",
            state: .failed, statusMessage: "Failed", createdAt: .distantPast, updatedAt: .distantPast)
        fixture.controller.workbench.archiveTask(old.id)
        fixture.enableHistorySync()
        try fixture.fail("project/list", "Unsupported")
        fixture.controller.performHistorySyncTick()
        try fixture.respond("thread/list", ["data": [fixture.thread(id: "new")], "nextCursor": "more"])
        fixture.controller.performHistorySyncTick()
        XCTAssertEqual(try fixture.params("thread/list")["cursor"] as? String, "more")
        try fixture.fail("thread/list", "Read failed")
        XCTAssertTrue(fixture.controller.workbench.isTaskArchived(old.id))
        XCTAssertEqual(fixture.controller.workbench.tasks.first { $0.id == old.id }?.state, .failed)
        XCTAssertEqual(Set(fixture.controller.workbench.tasks.compactMap(\.threadID)), ["old", "new"])
        fixture.controller.performHistorySyncTick(now: Date().addingTimeInterval(60))
        XCTAssertEqual(fixture.transport.requests("project/list").count, 1, "Unsupported projects should not be retried every poll")
    }

    func testStreamingDeltasCoalescePersistenceAndTerminalCompletionFlushesLatestText() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let initialWrites = fixture.controller.workbench.persistenceDiagnostics.writes
        for _ in 0..<100 {
            fixture.notify("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "answer", "delta": "x"])
        }
        XCTAssertEqual(fixture.controller.latestAgentMessage.count, 100, "The visible stream stays immediate")
        XCTAssertEqual(fixture.controller.workbench.persistenceDiagnostics.writes, initialWrites,
                       "A token burst must not encode the entire archive per delta")
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        fixture.controller.flushPendingTaskSnapshot()
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.latestAgentMessage, String(repeating: "x", count: 100))
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .completed)
        XCTAssertLessThanOrEqual(fixture.controller.workbench.persistenceDiagnostics.writes - initialWrites, 2)
        XCTAssertFalse(fixture.controller.workbench.persistenceDiagnostics.encodingOnMainThread)
        XCTAssertTrue(fixture.controller.workbench.persistenceDiagnostics.writesOnMainThread)
    }

    func testConnectionBoundaryFlushesPartialStreamBeforeRecovery() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.notify("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "answer", "delta": "Keep this partial"])
        fixture.controller.handleTransportFailure("Disconnected")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.latestAgentMessage, "Keep this partial")
        XCTAssertTrue(fixture.controller.isReconcilingConnection)
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        fixture.controller.startNewTask()
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
    }

    func testAutomaticReconciliationReadsOriginalThreadWithoutReplayingUnacknowledgedMessage() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.submit(prompt: "Original message", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        fixture.controller.handleTransportFailure("Lost acknowledgement")
        let recoveredID = try XCTUnwrap(fixture.controller.recoverableDrafts.first?.id)
        XCTAssertFalse(fixture.controller.canSubmit)
        fixture.controller.performScheduledReconciliation()
        XCTAssertEqual(try fixture.params("thread/read")["threadId"] as? String, "thread-1")
        XCTAssertEqual(try fixture.params("thread/read")["includeTurns"] as? Bool, true)
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.recoverableDrafts.map(\.id), [recoveredID])
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/steer").isEmpty)
        XCTAssertTrue(fixture.transport.messages.allSatisfy { $0["result"] == nil }, "Recovery must never answer an approval")
    }

    func testAutomaticReconciliationKeepsActiveSnapshotLockedAndMergesItemsWithoutDuplication() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.notify("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "answer", "delta": "Partial"])
        fixture.controller.handleTransportFailure("Disconnected")
        fixture.controller.performScheduledReconciliation()
        var thread = fixture.thread()
        thread["status"] = ["type": "active"]
        thread["turns"] = [["id": "turn-1", "status": "inProgress", "items": [["id": "answer", "type": "agentMessage", "text": "Partial answer"]]]]
        try fixture.respond("thread/read", ["thread": thread])
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.activities.filter { $0.serverItemID == "answer" }.count, 1)
        XCTAssertEqual(fixture.controller.latestAgentMessage, "Partial answer")
    }

    func testAutomaticReconciliationIsBoundedAndNeverUnlocksUnknownState() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.handleTransportFailure("Disconnected")
        for attempt in 1...3 {
            fixture.controller.performScheduledReconciliation()
            XCTAssertEqual(fixture.transport.requests("thread/read").count, attempt)
            try fixture.fail("thread/read", "Still unavailable")
        }
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.controller.statusMessage.contains("three attempts"))
        fixture.controller.performScheduledReconciliation()
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 3)
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)

        // Manual refresh after exhaustion must retain the same validation, and
        // an old turn or a thread-wide idle event cannot release the send lock.
        fixture.notify("turn/completed", ["turn": ["id": "older-turn", "status": "completed"]])
        fixture.notify("thread/status/changed", ["status": ["type": "idle"]])
        fixture.controller.refreshSelectedTask()
        try fixture.respond("thread/read", ["thread": fixture.thread()])
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.canSubmit)
        fixture.controller.refreshSelectedTask()
        var terminal = fixture.thread()
        terminal["turns"] = [["id": "turn-1", "status": "completed", "items": []]]
        try fixture.respond("thread/read", ["thread": terminal])
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testLeavingTaskCancelsRecoveryAndLateSnapshotCannotReplaceNewTask() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.handleTransportFailure("Disconnected")
        fixture.controller.performScheduledReconciliation()
        let read = try fixture.request("thread/read")
        fixture.controller.startNewTask()
        fixture.controller.performScheduledReconciliation()
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(read["id"]), "result": ["thread": fixture.thread()]])
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertNil(fixture.controller.workbench.selectedTask)
        XCTAssertTrue(fixture.controller.activities.isEmpty)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 1)
    }

    func testOldTurnAndForeignHistoryCannotResolveCurrentRecovery() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.handleTransportFailure("Disconnected")
        fixture.notify("turn/completed", ["turn": ["id": "older-turn", "status": "completed"]])
        XCTAssertTrue(fixture.controller.isReconcilingConnection)
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.canSubmit)
        fixture.controller.performScheduledReconciliation()
        try fixture.respond("thread/read", ["thread": fixture.thread(id: "foreign-thread")])
        XCTAssertTrue(fixture.controller.isReconcilingConnection)
        XCTAssertFalse(fixture.controller.canSubmit)
        fixture.controller.performScheduledReconciliation()
        var terminal = fixture.thread()
        terminal["turns"] = [["id": "turn-1", "status": "completed", "items": []]]
        try fixture.respond("thread/read", ["thread": terminal])
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testIdleSnapshotWithoutPreviouslyAcknowledgedTurnCannotUnlockRecovery() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.handleTransportFailure("Disconnected")
        fixture.controller.performScheduledReconciliation()
        try fixture.respond("thread/read", ["thread": fixture.thread()])
        XCTAssertTrue(fixture.controller.isReconcilingConnection)
        XCTAssertFalse(fixture.controller.canSubmit)
        fixture.controller.performScheduledReconciliation()
        var thread = fixture.thread()
        thread["turns"] = [["id": "turn-1", "status": "interrupted", "items": []]]
        try fixture.respond("thread/read", ["thread": thread])
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .interrupted)
    }

    func testNotLoadedHistoryDisplaysCompletedItemsWithoutResumingThread() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        var thread = fixture.completedThread(runtimeStatus: "notLoaded")
        thread["turns"] = [["id": "turn-1", "status": "completed", "items": [
            ["id": "answer", "type": "agentMessage", "text": "Saved history"]
        ]]]
        fixture.controller.refreshSelectedTask()
        try fixture.respond("thread/read", ["thread": thread])

        XCTAssertEqual(fixture.controller.latestAgentMessage, "Saved history")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .completed)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertNil(fixture.controller.capabilityErrors["thread/read"])
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
    }

    func testNotLoadedRecoveryRequiresTheOriginalTurnToHaveATerminalOutcome() throws {
        for unresolvedStatus in [nil, "inProgress", "futureStatus"] as [String?] {
            let fixture = try WorkspaceFixture()
            defer { fixture.cleanUp() }
            try fixture.startTurn()
            fixture.controller.handleTransportFailure("Disconnected")
            fixture.controller.performScheduledReconciliation()
            var incomplete = fixture.thread()
            incomplete["status"] = ["type": "notLoaded"]
            if let unresolvedStatus {
                incomplete["turns"] = [["id": "turn-1", "status": unresolvedStatus, "items": []]]
            }
            try fixture.respond("thread/read", ["thread": incomplete])
            XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
            XCTAssertFalse(fixture.controller.canSubmit)

            fixture.controller.performScheduledReconciliation()
            try fixture.respond("thread/read", ["thread": fixture.completedThread(runtimeStatus: "notLoaded")])

            XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
            XCTAssertFalse(fixture.controller.isReconcilingConnection)
            XCTAssertTrue(fixture.controller.canSubmit)
            XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .completed)
            XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
            XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        }
    }

    func testEmptyUnacknowledgedRecoveryCannotUseRuntimeLoadingStateAsCompletion() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.submit(prompt: "Lost ACK", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        fixture.controller.handleTransportFailure("Disconnected")
        fixture.controller.performScheduledReconciliation()
        var empty = fixture.thread()
        empty["status"] = ["type": "notLoaded"]
        try fixture.respond("thread/read", ["thread": empty])
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.canSubmit)
        fixture.controller.performScheduledReconciliation()
        try fixture.respond("thread/read", ["thread": fixture.completedThread(runtimeStatus: "notLoaded")])
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.recoverableDrafts.count, 1)
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
    }

    func testSystemErrorHistoryIsVisibleButNeverPresentedAsSuccessfulCompletion() throws {
        for turnStatus in ["completed", "inProgress"] {
            let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
            defer { fixture.cleanUp() }
            var thread = fixture.thread()
            thread["status"] = ["type": "systemError"]
            thread["turns"] = [["id": "turn-1", "status": turnStatus, "items": [
                ["id": "answer", "type": "agentMessage", "text": "Last saved response"]
            ]]]
            fixture.controller.refreshSelectedTask()
            try fixture.respond("thread/read", ["thread": thread])

            XCTAssertEqual(fixture.controller.latestAgentMessage, "Last saved response")
            XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .failed)
            XCTAssertTrue(fixture.controller.statusMessage.contains("runtime error"))
            XCTAssertEqual(fixture.controller.isTaskStatusUncertain, turnStatus == "inProgress")
            XCTAssertEqual(fixture.controller.canSubmit, turnStatus == "completed")
        }
    }

    func testSystemErrorDuringRecoveryDoesNotUnlockAnUnfinishedTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.handleTransportFailure("Disconnected")
        fixture.controller.performScheduledReconciliation()
        var thread = fixture.thread()
        thread["status"] = ["type": "systemError"]
        thread["turns"] = [["id": "turn-1", "status": "inProgress", "items": []]]
        try fixture.respond("thread/read", ["thread": thread])
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.canSubmit)

        fixture.controller.performScheduledReconciliation()
        try fixture.respond("thread/read", ["thread": fixture.completedThread(runtimeStatus: "systemError")])
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .failed)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
    }

    func testKnownCurrentTurnNotificationResolvesUncertaintyWithoutReplaying() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.handleTransportFailure("Disconnected")
        fixture.controller.receiveServerMessage(["method": "turn/completed", "params": [
            "turn": ["id": "turn-1", "status": "completed"]
        ]])
        XCTAssertTrue(fixture.controller.isTaskStatusUncertain, "An unscoped event cannot resolve lost transport state")

        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])

        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertFalse(fixture.controller.isReconcilingConnection)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
    }

    func testHydratingHistoryPreservesItemCompletionBeforeTurnCompletion() throws {
        for turnStatus in ["inProgress", "completed", "futureStatus"] {
            let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
            defer { fixture.cleanUp() }
            var thread = fixture.thread()
            thread["status"] = ["type": turnStatus == "inProgress" ? "active" : "idle"]
            thread["turns"] = [["id": "turn-1", "status": turnStatus, "items": [
                ["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Begin"]]],
                ["id": "done", "type": "commandExecution", "command": "true", "status": "completed"],
                ["id": "failed", "type": "commandExecution", "command": "false", "status": "failed"],
                ["id": "active", "type": "commandExecution", "command": "sleep", "status": "inProgress"],
                ["id": "unknown", "type": "commandExecution", "command": "future", "status": "futureStatus"],
                ["id": "exit", "type": "commandExecution", "command": "false", "exitCode": 1],
                ["id": "success", "type": "dynamicToolCall", "success": false],
                ["id": "missing", "type": "agentMessage", "text": "Partial"]
            ]]]
            fixture.controller.refreshSelectedTask()
            try fixture.respond("thread/read", ["thread": thread])

            let byID = Dictionary(uniqueKeysWithValues: fixture.controller.activities.compactMap { item in
                item.serverItemID.map { ($0, item.isComplete) }
            })
            for id in ["done", "failed", "exit", "success"] { XCTAssertEqual(byID[id], true, id) }
            for id in ["active", "unknown"] { XCTAssertEqual(byID[id], false, id) }
            XCTAssertEqual(byID["missing"], turnStatus == "completed")
        }
    }

    func testHydratedCompletedCommandDoesNotPresentAsRunningWhileTurnContinues() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        var thread = fixture.thread()
        thread["status"] = ["type": "active"]
        thread["turns"] = [["id": "turn-1", "status": "inProgress", "items": [
            ["id": "user", "type": "userMessage", "content": [["type": "text", "text": "Begin"]]],
            ["id": "done", "type": "commandExecution", "command": "true", "status": "completed"]
        ]]]
        fixture.controller.refreshSelectedTask()
        try fixture.respond("thread/read", ["thread": thread])

        XCTAssertEqual(CodexRunPresentation.resolve(isRunning: true, requiresInput: false,
                                                    activities: fixture.controller.activities), .working)
    }

    func testThreadContextUsageDoesNotLeakAcrossTasksOrAcceptForeignEvents() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let value: [String: Any] = [
            "last": ["inputTokens": 80, "outputTokens": 20, "cachedInputTokens": 50, "totalTokens": 100],
            "total": ["totalTokens": 9_000], "modelContextWindow": 1_000
        ]
        fixture.notify("thread/tokenUsage/updated", ["turnId": "turn-1", "tokenUsage": value])
        XCTAssertEqual(fixture.controller.activeTokenUsage?.lastTotalTokens, 100)
        fixture.controller.receiveServerMessage(["method": "thread/tokenUsage/updated",
            "params": ["threadId": "foreign", "turnId": "foreign-turn", "tokenUsage": [
                "last": ["inputTokens": 999, "outputTokens": 0, "cachedInputTokens": 0, "totalTokens": 999]
            ]]])
        XCTAssertEqual(fixture.controller.activeTokenUsage?.lastTotalTokens, 100)
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        fixture.controller.startNewTask()
        XCTAssertNil(fixture.controller.activeTokenUsage)
    }

    func testUnknownRemoteTurnDoesNotBorrowSelectedModelForUsage() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        try fixture.loadUsageTestModels()
        fixture.controller.selectModel("model-B")
        var remoteThread = fixture.thread()
        remoteThread["status"] = ["type": "active"]
        remoteThread["turns"] = [["id": "remote-model-A-turn", "status": "inProgress", "items": []]]
        fixture.controller.refreshSelectedTask()
        try fixture.respond("thread/read", ["thread": remoteThread])
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        fixture.controller.selectModel("model-A")
        fixture.controller.selectReasoningEffort("high")
        XCTAssertEqual(fixture.controller.selectedModel, "model-B", "A background active turn must lock model selection")
        XCTAssertEqual(fixture.controller.selectedReasoningEffort, "low")
        fixture.notify("thread/tokenUsage/updated", [
            "turnId": "remote-model-A-turn", "tokenUsage": fixture.usageValue()
        ])
        XCTAssertNil(fixture.controller.activeTokenUsage,
            "thread/read does not identify the active model, so its usage cannot be labeled with this client's preference")
    }

    func testDelayedUsageRetainsSubmittedModelAfterModelSelectionChanges() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.loadUsageTestModels()
        fixture.controller.selectModel("model-A")
        try fixture.startTurn()
        XCTAssertEqual(try fixture.params("turn/start")["model"] as? String, "model-A")
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        fixture.controller.selectModel("model-B")
        fixture.notify("thread/tokenUsage/updated", ["turnId": "turn-1", "tokenUsage": fixture.usageValue()])
        XCTAssertNil(fixture.controller.activeTokenUsage, "A delayed model A event must not become model B usage")
        fixture.controller.selectModel("model-A")
        XCTAssertEqual(fixture.controller.activeTokenUsage?.model, "model-A")
        XCTAssertEqual(fixture.controller.activeTokenUsage?.lastTotalTokens, 100)
    }

    func testCommandUsageUsesModelConfirmedByResumeResponse() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        try fixture.loadUsageTestModels()
        fixture.controller.selectModel("model-B")
        XCTAssertTrue(fixture.controller.executeSlashCommand("/review"))
        try fixture.respond("thread/resume", ["thread": fixture.thread(), "model": "model-A"])
        fixture.notify("turn/started", ["turn": ["id": "review-turn"]])
        fixture.notify("thread/tokenUsage/updated", ["turnId": "review-turn", "tokenUsage": fixture.usageValue()])
        XCTAssertNil(fixture.controller.activeTokenUsage, "The server-confirmed command model takes precedence over the picker")
        fixture.notify("turn/completed", ["turn": ["id": "review-turn", "status": "completed"]])
        fixture.controller.selectModel("model-A")
        XCTAssertEqual(fixture.controller.activeTokenUsage?.model, "model-A")
    }

    func testConversationStreamReconcilesCompletedMessagesWithoutDuplicatingDeltas() {
        var response = CodexConversationResponseAccumulator()
        XCTAssertTrue(response.receive(method: "item/agentMessage/delta", params: ["itemId": "one", "delta": "First "]))
        XCTAssertEqual(response.text, "First ")
        XCTAssertTrue(response.receive(method: "item/agentMessage/delta", params: ["itemId": "one", "delta": "answer"]))
        XCTAssertFalse(response.receive(method: "item/completed", params: [
            "item": ["id": "one", "type": "agentMessage", "text": "First answer"]
        ]))
        XCTAssertEqual(response.text, "First answer")
        XCTAssertTrue(response.receive(method: "item/agentMessage/delta", params: ["itemId": "two", "delta": "Second"]))
        XCTAssertEqual(response.text, "First answer\n\nSecond")
        XCTAssertTrue(response.receive(method: "item/completed", params: [
            "item": ["id": "two", "type": "agentMessage", "text": "Second answer"]
        ]))
        XCTAssertEqual(response.text, "First answer\n\nSecond answer")
        XCTAssertFalse(response.receive(method: "item/completed", params: [
            "item": ["id": "tool", "type": "commandExecution", "text": "Tool output"]
        ]))
    }

    func testConversationAccumulatorExcludesCommentaryFromStreamingAndCompletedReply() {
        var response = CodexConversationResponseAccumulator()
        XCTAssertFalse(response.receive(method: "item/started", params: ["item": [
            "id": "progress", "type": "agentMessage", "phase": "commentary", "text": ""]]))
        XCTAssertFalse(response.receive(method: "item/agentMessage/delta", params: ["itemId": "progress", "delta": "Let me check."]))
        XCTAssertFalse(response.receive(method: "item/completed", params: ["item": [
            "id": "progress", "type": "agentMessage", "phase": "commentary", "text": "Let me check."]]))
        XCTAssertTrue(response.text.isEmpty)
        XCTAssertTrue(response.receive(method: "item/completed", params: ["item": [
            "id": "answer", "type": "agentMessage", "phase": "final_answer", "text": "The answer."]]))
        XCTAssertEqual(response.text, "The answer.")
        XCTAssertTrue(response.receive(method: "item/agentMessage/delta", params: ["itemId": "late", "delta": "Cleaning up."]))
        XCTAssertTrue(response.receive(method: "item/completed", params: ["item": [
            "id": "late", "type": "agentMessage", "phase": "commentary", "text": "Cleaning up."]]))
        XCTAssertEqual(response.text, "The answer.", "Late metadata corrects the answer without repeating progress")
    }

    func testRestoredRunningTaskWaitsForReadBeforeAcceptingAnotherSubmission() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", restoredState: .running)
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.transport.messages.isEmpty, "Restoring local state must not start the runtime")
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertFalse(fixture.controller.submit(prompt: "Do not duplicate work", images: []))

        fixture.controller.refreshSkills()
        XCTAssertEqual(try fixture.params("thread/read")["threadId"] as? String, "thread-1")
        XCTAssertTrue(fixture.controller.isReadingSelectedTask)
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])

        XCTAssertFalse(fixture.controller.isRemoteTaskActive)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.controller.submit(prompt: "Continue confirmed idle work", images: []))
        XCTAssertEqual(try fixture.params("thread/resume")["threadId"] as? String, "thread-1")
    }

    func testRestoredRunningTaskReadFailureCanRetryAndNewChatCanLeaveUncertainState() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", restoredState: .running)
        defer { fixture.cleanUp() }
        fixture.controller.refreshSkills()
        try fixture.fail("thread/read", "Temporary history failure")
        XCTAssertFalse(fixture.controller.isReadingSelectedTask)
        XCTAssertTrue(fixture.controller.isRemoteTaskActive)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.controller.statusMessage.contains("Refresh this chat"))

        fixture.controller.refreshSelectedTask()
        XCTAssertEqual(fixture.transport.requests("thread/read").count, 2)
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertNil(fixture.controller.capabilityErrors["thread/read"])

        for connectBeforeLeaving in [false, true] {
            let abandoned = try WorkspaceFixture(restoredThreadID: "thread-1", restoredState: .running)
            defer { abandoned.cleanUp() }
            if connectBeforeLeaving {
                abandoned.controller.refreshSkills()
                try abandoned.fail("thread/read", "History unavailable")
            }
            let readCount = abandoned.transport.requests("thread/read").count
            abandoned.controller.startNewTask()
            XCTAssertTrue(abandoned.controller.canSubmit)
            XCTAssertFalse(abandoned.controller.isRemoteTaskActive)
            abandoned.controller.refreshSkills()
            XCTAssertEqual(abandoned.transport.requests("thread/read").count, readCount,
                           "Leaving must discard the deferred read for the previous chat")
        }
    }

    func testCorrectedOrResolvedInteractionDoesNotLeakValidationErrorsToLaterApprovals() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        func requestForm(id: String) throws -> CodexInteractionRequest {
            fixture.controller.receiveServerMessage(["id": id, "method": "mcpServer/elicitation/request", "params": [
                "threadId": "thread-1", "turnId": "turn-1", "mode": "form",
                "requestedSchema": ["type": "object", "required": ["count"], "properties": [
                    "count": ["type": "integer", "minimum": 1]
                ]]
            ]])
            return try XCTUnwrap(fixture.controller.pendingInteractions.first { $0.id == .string(id) })
        }
        let form = try requestForm(id: "form-1")
        fixture.controller.respondToInteraction(form, action: .accept, formValues: ["count": "invalid"])
        XCTAssertNotNil(fixture.controller.interactionErrors[form.id])
        fixture.controller.respondToInteraction(form, action: .accept, formValues: ["count": "2"])
        XCTAssertNil(fixture.controller.interactionErrors[form.id])
        XCTAssertTrue(fixture.controller.pendingInteractions.isEmpty)

        let resolvedForm = try requestForm(id: "form-2")
        fixture.controller.respondToInteraction(resolvedForm, action: .accept, formValues: ["count": "not-an-integer"])
        XCTAssertNotNil(fixture.controller.interactionErrors[resolvedForm.id])
        fixture.controller.receiveServerMessage(["id": "approval", "method": "item/commandExecution/requestApproval",
            "params": ["threadId": "thread-1", "turnId": "turn-1", "command": "Run checks"]])
        XCTAssertEqual(fixture.controller.pendingInteractions.count, 2)
        XCTAssertNotNil(fixture.controller.interactionErrors[resolvedForm.id],
                        "A second request must not erase the first request's validation error")
        XCTAssertNil(fixture.controller.interactionErrors[.string("approval")],
                     "The queued approval must not display another request's form error")
        fixture.notify("serverRequest/resolved", ["requestId": "form-2"])
        XCTAssertNil(fixture.controller.interactionErrors[resolvedForm.id])
        XCTAssertNil(fixture.controller.interactionErrors[.string("approval")])
        XCTAssertEqual(fixture.controller.pendingInteractions.count, 1)

        let pendingForm = try requestForm(id: "form-3")
        fixture.controller.respondToInteraction(pendingForm, action: .accept, formValues: ["count": "not-an-integer"])
        XCTAssertNotNil(fixture.controller.interactionErrors[pendingForm.id])
        let approval = try XCTUnwrap(fixture.controller.pendingInteractions.first { $0.id == .string("approval") })
        let decision = try XCTUnwrap(approval.approvalDecisions.first)
        fixture.controller.respondToApprovalDecision(approval, decision: decision)
        XCTAssertNotNil(fixture.controller.interactionErrors[pendingForm.id],
                        "Answering a different request must preserve this form's validation error")
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.pendingInteractions.isEmpty)
        XCTAssertTrue(fixture.controller.interactionErrors.isEmpty)
    }

    func testArchivingASelectedLocalFailureStartsTheNextSubmissionInANewTask() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.submit(prompt: "First request", images: []))
        try fixture.fail("thread/start", "Runtime unavailable")
        let failedTask = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        XCTAssertNil(failedTask.threadID)
        XCTAssertEqual(failedTask.state, .failed)

        fixture.controller.archiveTask(failedTask)

        XCTAssertTrue(fixture.controller.workbench.isTaskArchived(failedTask.id))
        XCTAssertNil(fixture.controller.workbench.selectedTask)
        XCTAssertTrue(fixture.controller.activities.isEmpty)
        XCTAssertTrue(fixture.controller.submit(prompt: "Second request", images: []))
        let nextTask = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        XCTAssertNotEqual(nextTask.id, failedTask.id)
        XCTAssertEqual(nextTask.title, "Second request")
        XCTAssertTrue(fixture.controller.savedTasks.contains { $0.id == nextTask.id })
        XCTAssertFalse(fixture.controller.savedTasks.contains { $0.id == failedTask.id })
        XCTAssertEqual(fixture.controller.workbench.tasks.first { $0.id == failedTask.id }?.state, .failed)
    }

    func testRefreshingTerminalHistoryKeepsFailedAndInterruptedOutcomes() throws {
        for (status, expectedState) in [("failed", SavedTaskState.failed), ("interrupted", .interrupted)] {
            let fixture = try WorkspaceFixture()
            defer { fixture.cleanUp() }
            try fixture.startTurn()
            fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": status]])
            XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, expectedState)
            var thread = fixture.thread()
            thread["turns"] = [[
                "id": "turn-1", "status": status, "durationMs": 2_000,
                "error": status == "failed" ? ["message": "The model could not finish"] as Any : NSNull(),
                "items": [
                    ["id": "user-1", "type": "userMessage", "content": [["type": "text", "text": "Begin"]]],
                    ["id": "answer-1", "type": "agentMessage", "text": "Partial response"]
                ]
            ]]

            for _ in 0..<2 {
                fixture.controller.refreshSelectedTask()
                try fixture.respond("thread/read", ["thread": thread])

                XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, expectedState)
                XCTAssertEqual(fixture.controller.statusMessage, "Codex task \(status).")
                let errors = fixture.controller.activities.filter { $0.kind == .error }
                XCTAssertEqual(errors.count, 1, "Refreshing must neither erase nor duplicate the terminal outcome")
                XCTAssertEqual(errors.first?.title, "Codex task \(status)")
                XCTAssertEqual(errors.first?.turnID, "turn-1")
                XCTAssertEqual(errors.first?.detail, status == "failed" ? "The model could not finish" : "")
                XCTAssertTrue(fixture.controller.canSubmit)
            }
        }
    }

    func testHistoryRetainsEarlierFailureWithoutOverridingTheLatestTurnState() throws {
        for isRemoteActive in [false, true] {
            let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
            defer { fixture.cleanUp() }
            var thread = fixture.thread()
            thread["status"] = ["type": isRemoteActive ? "active" : "idle"]
            thread["turns"] = [
                ["id": "failed-turn", "status": "failed", "error": ["message": "Earlier failure"], "items": []],
                ["id": "latest-turn", "status": isRemoteActive ? "inProgress" : "completed", "items": [
                    ["id": "latest-user", "type": "userMessage", "content": [["type": "text", "text": "Try again"]]]
                ]]
            ]

            fixture.controller.refreshSelectedTask()
            try fixture.respond("thread/read", ["thread": thread])

            XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, isRemoteActive ? .running : .completed)
            XCTAssertEqual(fixture.controller.isRemoteTaskActive, isRemoteActive)
            XCTAssertEqual(fixture.controller.canSubmit, !isRemoteActive)
            XCTAssertEqual(fixture.controller.activities.filter { $0.kind == .error }.map(\.detail), ["Earlier failure"])
            XCTAssertEqual(fixture.controller.activities.first { $0.kind == .error }?.turnID, "failed-turn")
        }
    }

    func testStopSendsThreadAndTurnIDsAndWaitsForCompletion() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()

        fixture.controller.interrupt()

        let params = try fixture.params("turn/interrupt")
        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        XCTAssertEqual(params["turnId"] as? String, "turn-1")
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertFalse(fixture.controller.canSteer)
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "interrupted"]])
        XCTAssertFalse(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testStopBeforeTurnReplyInterruptsAsSoonAsItsIDArrives() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.submit(prompt: "Begin", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])

        fixture.controller.interrupt()
        XCTAssertTrue(fixture.transport.requests("turn/interrupt").isEmpty)
        XCTAssertTrue(fixture.controller.isRunning)
        try fixture.respond("turn/start", ["turn": ["id": "delayed-turn"]])

        XCTAssertEqual(try fixture.params("turn/interrupt")["turnId"] as? String, "delayed-turn")
        XCTAssertTrue(fixture.controller.isRunning)
    }

    func testStopBeforeThreadCreationDiscardsItsLateReply() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.submit(prompt: "Begin", images: []))
        let request = try fixture.request("thread/start")

        fixture.controller.interrupt()
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(request["id"]), "result": ["thread": fixture.thread()]])

        XCTAssertFalse(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .interrupted)
    }

    func testRetryableErrorDoesNotUnlockAnActiveTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()

        fixture.notify("error", ["error": ["message": "Temporary failure"], "willRetry": true])

        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.controller.canSteer)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .running)
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testUnknownStringIDRequestGetsJSONRPCErrorWithoutEndingTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()

        fixture.controller.receiveServerMessage(["id": "future-request", "method": "future/client/request", "params": [:]])

        let response = try XCTUnwrap(fixture.transport.messages.last)
        XCTAssertEqual(response["id"] as? String, "future-request")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertNil(response["result"])
        XCTAssertTrue(fixture.controller.isRunning)
    }

    func testInteractionsQueueDeduplicatesResolvesAndAnswersTheRemainingQuestion() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let question: [String: Any] = [
            "id": "question-1", "method": "item/tool/requestUserInput", "params": [
                "threadId": "thread-1", "turnId": "turn-1", "questions": [[
                    "id": "choice", "header": "Target", "question": "Which target?",
                    "options": [["label": "Local", "description": "Use local files"]], "isOther": false
                ]]
            ]
        ]
        fixture.controller.receiveServerMessage(question)
        fixture.controller.receiveServerMessage(question)
        fixture.controller.receiveServerMessage([
            "id": 402, "method": "item/permissions/requestApproval", "params": [
                "threadId": "thread-1", "turnId": "turn-1", "permissions": ["network": ["enabled": true]]
            ]
        ])
        XCTAssertEqual(fixture.controller.pendingInteractions.count, 2)

        fixture.notify("serverRequest/resolved", ["requestId": 402])
        let remaining = try XCTUnwrap(fixture.controller.pendingInteractions.first)
        XCTAssertEqual(remaining.id, .string("question-1"))
        fixture.controller.respondToInteraction(remaining, action: .accept, answers: ["choice": ["Local"]])

        let response = try XCTUnwrap(fixture.transport.messages.last)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let answers = try XCTUnwrap(result["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(response["id"] as? String, "question-1")
        XCTAssertEqual(answers["choice"]?["answers"], ["Local"])
        XCTAssertTrue(fixture.controller.pendingInteractions.isEmpty)
        let count = fixture.transport.messages.count
        fixture.controller.respondToInteraction(remaining, action: .accept, answers: ["choice": ["Local"]])
        XCTAssertEqual(fixture.transport.messages.count, count)
    }

    func testFollowUpKeepsEarlierTurnsAndMergesRepeatedServerItems() throws {
        let previous = WorkActivity(kind: .message, title: "Codex", detail: "Earlier answer",
                                     turnID: "turn-0", serverItemID: "answer-0")
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", cachedActivities: [previous])
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.submit(prompt: "Follow up", images: []))
        try fixture.respond("thread/resume", ["thread": fixture.thread()])
        try fixture.respond("turn/start", ["turn": ["id": "turn-1"]])
        fixture.notify("item/started", ["turnId": "turn-1", "item": ["id": "answer-1", "type": "agentMessage", "text": ""]])
        let itemID = try XCTUnwrap(fixture.controller.activities.first { $0.serverItemID == "answer-1" }?.id)
        fixture.notify("item/agentMessage/delta", ["turnId": "turn-1", "itemId": "answer-1", "delta": "New answer"])
        let completed: [String: Any] = ["turnId": "turn-1", "item": ["id": "answer-1", "type": "agentMessage", "text": "New answer"]]
        fixture.notify("item/completed", completed)
        fixture.notify("item/completed", completed)
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])

        XCTAssertTrue(fixture.controller.activities.contains { $0.id == previous.id && $0.detail == "Earlier answer" })
        let newItems = fixture.controller.activities.filter { $0.serverItemID == "answer-1" }
        XCTAssertEqual(newItems.count, 1)
        XCTAssertEqual(newItems.first?.id, itemID)
        XCTAssertEqual(newItems.first?.detail, "New answer")
        XCTAssertEqual(newItems.first?.turnID, "turn-1")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.activities.filter { $0.kind == .message }.count, 2)
    }

    func testUnrecognizedToolItemsRetainTheirPayloadAndCompletionState() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let item: [String: Any] = ["id": "future-tool", "type": "futureTool", "result": ["resourceUri": "artifact://report", "answer": 42]]

        fixture.notify("item/started", ["turnId": "turn-1", "item": item])
        fixture.notify("item/completed", ["turnId": "turn-1", "item": item])

        let activity = try XCTUnwrap(fixture.controller.activities.first { $0.serverItemID == "future-tool" })
        let raw = try XCTUnwrap(activity.rawJSON?.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "futureTool")
        XCTAssertEqual((payload["result"] as? [String: Any])?["resourceUri"] as? String, "artifact://report")
        XCTAssertTrue(activity.isComplete)
        XCTAssertEqual(fixture.controller.activities.filter { $0.serverItemID == "future-tool" }.count, 1)
    }

    func testDocumentAndImageAttachmentsUsePersistentFilesWithoutChangingTheWorkspace() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let existingFile = fixture.directory.appendingPathComponent("existing.txt")
        try Data("Keep the original file".utf8).write(to: existingFile)
        let csv = ConversationImageAsset(data: Data("name,value\nalpha,42\n".utf8), mimeType: "text/csv", fileName: "../../report.csv")
        let image = ConversationImageAsset(data: Data([1, 2, 3, 4]), mimeType: "image/png", fileName: "capture.png")
        XCTAssertTrue(fixture.controller.submit(prompt: "Read the files", images: [csv, image]))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let input = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        let fileReference = try XCTUnwrap(input.compactMap { $0["text"] as? String }.first { $0.contains("Local path: ") })
        let documentPath = try XCTUnwrap(fileReference.components(separatedBy: "Local path: ").last)
        let imagePath = try XCTUnwrap(input.first { $0["type"] as? String == "localImage" }?["path"] as? String)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: documentPath)), csv.data)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), image.data)
        XCTAssertTrue(documentPath.hasPrefix(fixture.attachmentDirectory.path + "/"))
        XCTAssertTrue(imagePath.hasPrefix(fixture.attachmentDirectory.path + "/"))
        XCTAssertFalse(documentPath.hasPrefix(fixture.directory.path + "/"))
        XCTAssertFalse(documentPath.contains("../"))
        XCTAssertEqual(input.filter { $0["type"] as? String == "localImage" }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["existing.txt"])
        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), "Keep the original file")
    }

    func testRestoredThreadUsesItsWorkspaceAndDoesNotOverrideServerPermissions() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.controller.workspaceURL?.path, fixture.directory.path)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.workspaceID, fixture.controller.workbench.selectedWorkspaceID)

        XCTAssertTrue(fixture.controller.submit(prompt: "Continue", images: []))
        XCTAssertEqual(try fixture.params("thread/resume")["threadId"] as? String, "thread-1")
        try fixture.respond("thread/resume", ["thread": fixture.thread()])

        let params = try fixture.params("turn/start")
        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        XCTAssertNil(params["cwd"])
        XCTAssertNil(params["sandboxPolicy"])
        XCTAssertNil(params["approvalPolicy"])
    }

    func testReadingMovedThreadAdoptsItsDirectoryAndKeepsAttachmentsOutsideTheWorkspace() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        let moved = fixture.directory.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        fixture.controller.refreshSelectedTask()
        try fixture.respond("thread/read", ["thread": fixture.thread(cwd: moved.path)])
        XCTAssertEqual(fixture.controller.workspaceURL?.path, moved.path)
        let selected = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        XCTAssertEqual(fixture.controller.workbench.workspaces.first { $0.id == selected.workspaceID }?.path, moved.path)

        let file = ConversationImageAsset(data: Data("content".utf8), mimeType: "text/plain", fileName: "notes.txt")
        XCTAssertTrue(fixture.controller.submit(prompt: "Use this", images: [file]))
        try fixture.respond("thread/resume", ["thread": fixture.thread(cwd: moved.path)])
        let input = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertTrue(input.compactMap { $0["text"] as? String }.contains { $0.contains(fixture.attachmentDirectory.path + "/") })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testCapabilityFailureAndPaginationDoNotCompleteAnActiveTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.refreshCapabilities()
        fixture.controller.refreshApps()
        fixture.controller.refreshPlugins()
        fixture.controller.refreshMCPServers()
        try fixture.fail("skills/list", "Skills unavailable")
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.capabilityErrors["skills/list"], "Skills unavailable")
        try fixture.respond("app/list", ["data": [["id": "app-a", "name": "App A", "isAccessible": true]], "nextCursor": "apps-page-2"])
        XCTAssertEqual(try fixture.params("app/list")["cursor"] as? String, "apps-page-2")
        try fixture.respond("app/list", ["data": [["id": "app-b", "name": "App B", "isAccessible": false]]])
        try fixture.fail("plugin/list", "Unknown method")
        XCTAssertEqual(fixture.transport.requests("plugin/installed").count, 1)
        XCTAssertTrue(fixture.controller.isLoadingCapabilities)
        try fixture.respond("plugin/installed", ["marketplaces": []])
        try fixture.respond("mcpServerStatus/list", ["data": []])
        try fixture.respond("collaborationMode/list", ["data": []])

        XCTAssertEqual(Set(fixture.controller.extensions.filter { $0.kind == "App" }.map(\.name)), ["App A", "App B"])
        XCTAssertFalse(fixture.controller.isLoadingCapabilities)
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .running)
    }

    func testSelectedEnabledSkillUsesAnExplicitSkillInput() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshCapabilities()
        try fixture.respond("skills/list", ["data": [[
            "cwd": fixture.directory.path, "skills": [
                ["name": "reader", "path": "/tmp/skills/reader/SKILL.md", "enabled": true],
                ["name": "disabled", "path": "/tmp/skills/disabled/SKILL.md", "enabled": false]
            ], "errors": []
        ]]])
        let skill = try XCTUnwrap(fixture.controller.skills.first { $0.name == "reader" })
        let disabled = try XCTUnwrap(fixture.controller.skills.first { $0.name == "disabled" })
        fixture.controller.toggleSkillSelection(skill)
        fixture.controller.toggleSkillSelection(disabled)

        XCTAssertTrue(fixture.controller.submit(prompt: "Read the paper with $reader", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let input = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        let skillInputs = input.filter { $0["type"] as? String == "skill" }

        XCTAssertEqual(input.first?["text"] as? String, "Read the paper with $reader")
        XCTAssertEqual(skillInputs.count, 1)
        XCTAssertEqual(skillInputs.first?["name"] as? String, "reader")
        XCTAssertEqual(skillInputs.first?["path"] as? String, skill.path)
    }

    func testPlanSelectionUsesTheRuntimeCollaborationModeWireStructure() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshCapabilities()
        try fixture.respond("collaborationMode/list", ["data": [[
            "name": "Plan", "mode": "plan", "model": "catalog-default", "reasoning_effort": "high"
        ]]])
        let mode = try XCTUnwrap(fixture.controller.collaborationModes.first)
        fixture.controller.selectCollaborationMode(mode.id)
        XCTAssertTrue(fixture.controller.submit(prompt: "Plan this change", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])

        let collaboration = try XCTUnwrap(try fixture.params("turn/start")["collaborationMode"] as? [String: Any])
        let settings = try XCTUnwrap(collaboration["settings"] as? [String: Any])
        XCTAssertEqual(collaboration["mode"] as? String, "plan")
        XCTAssertEqual(settings["model"] as? String, fixture.controller.selectedModel)
        XCTAssertEqual(settings["reasoning_effort"] as? String, "high")
        XCTAssertTrue(settings["developer_instructions"] is NSNull)
    }

    func testSubmittingWhileRunningSteersTheExpectedTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let starts = fixture.transport.requests("turn/start").count

        XCTAssertTrue(fixture.controller.submit(prompt: "Also include the tests", images: []))

        let params = try fixture.params("turn/steer")
        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        XCTAssertEqual(params["expectedTurnId"] as? String, "turn-1")
        XCTAssertEqual((params["input"] as? [[String: Any]])?.first?["text"] as? String, "Also include the tests")
        XCTAssertEqual(fixture.transport.requests("turn/start").count, starts)
        XCTAssertTrue(fixture.controller.isRunning)
    }

    func testLateEventsFromPreviousTurnCannotCompleteOrFailTheNewTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.submit(prompt: "Next question", images: []))
        try fixture.respond("turn/start", ["turn": ["id": "turn-2"]])

        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "failed"]])
        fixture.notify("error", ["turnId": "turn-1", "error": ["message": "Stale failure"], "willRetry": false])

        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.canSteer)
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .running)
        XCTAssertFalse(fixture.controller.activities.contains { $0.detail == "Stale failure" })
        fixture.controller.interrupt()
        XCTAssertEqual(try fixture.params("turn/interrupt")["turnId"] as? String, "turn-2")
    }

    func testChangingWorkspaceClearsSkillsAndIgnoresThePreviousCatalogResponse() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let catalog: [String: Any] = ["data": [["cwd": fixture.directory.path, "skills": [
            ["name": "project-skill", "path": fixture.directory.appendingPathComponent("SKILL.md").path, "enabled": true]
        ], "errors": []]]]
        fixture.controller.refreshCapabilities()
        fixture.controller.refreshApps()
        fixture.controller.refreshPlugins()
        fixture.controller.refreshMCPServers()
        try fixture.respond("skills/list", catalog)
        try fixture.respond("app/list", ["data": []])
        try fixture.respond("plugin/list", ["marketplaces": []])
        try fixture.respond("mcpServerStatus/list", ["data": []])
        try fixture.respond("collaborationMode/list", ["data": []])
        let skill = try XCTUnwrap(fixture.controller.skills.first)
        fixture.controller.toggleSkillSelection(skill)
        XCTAssertEqual(fixture.controller.selectedSkillPaths, [skill.path])
        fixture.controller.refreshCapabilities()
        let oldRequest = try fixture.request("skills/list")
        fixture.controller.refreshApps()
        let oldAppsRequest = try fixture.request("app/list")
        let otherDirectory = fixture.directory.appendingPathComponent("other-project", isDirectory: true)
        let other = fixture.controller.workbench.ensureWorkspace(url: otherDirectory)

        fixture.controller.selectWorkspace(other)
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldRequest["id"]), "result": catalog])

        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldAppsRequest["id"]), "result": ["data": [["id": "old-app", "name": "Previous project app", "isAccessible": true]]]])
        XCTAssertTrue(fixture.controller.extensions.isEmpty)
        XCTAssertEqual(fixture.controller.workspaceURL?.path, otherDirectory.path)
        XCTAssertTrue(fixture.controller.skills.isEmpty)
        XCTAssertTrue(fixture.controller.selectedSkillPaths.isEmpty)
        XCTAssertFalse(fixture.controller.isLoadingCapabilities)
    }

    func testHistorySnapshotCannotOverwriteAThreadThatStartedLocallyAfterTheRequest() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.loadAllTaskHistory()
        let oldHistoryRequest = try fixture.request("thread/list")
        try fixture.startTurn()
        fixture.notify("item/completed", ["turnId": "turn-1", "item": [
            "id": "current-user", "type": "userMessage", "content": [["type": "text", "text": "Begin"]]
        ]])
        let currentActivities = fixture.controller.activities
        let currentTaskID = fixture.controller.workbench.selectedTaskID
        var oldThread = fixture.thread()
        oldThread["name"] = "Outdated title"

        fixture.controller.receiveServerMessage([
            "id": try XCTUnwrap(oldHistoryRequest["id"]), "result": ["data": [oldThread]]
        ])
        try fixture.respond("thread/list", ["data": []])

        XCTAssertFalse(fixture.controller.isLoadingTaskHistory)
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.workbench.selectedTaskID, currentTaskID)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .running)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.title, "Begin")
        XCTAssertEqual(fixture.controller.activities, currentActivities)
        XCTAssertTrue(fixture.transport.requests("thread/read").isEmpty)
    }

    func testRequestTimeoutKeepsActiveWorkAndRequiresRefreshForAnUnacknowledgedStart() throws {
        let active = try WorkspaceFixture()
        defer { active.cleanUp() }
        try active.startTurn()
        active.controller.refreshCapabilities()
        let skillRequestID = try XCTUnwrap(try active.request("skills/list")["id"] as? Int)

        active.controller.expireServerRequest(skillRequestID)

        XCTAssertNotNil(active.controller.capabilityErrors["skills/list"])
        XCTAssertTrue(active.controller.isRunning)
        XCTAssertTrue(active.controller.canSteer)
        XCTAssertEqual(active.controller.workbench.selectedTask?.state, .running)

        let unacknowledged = try WorkspaceFixture()
        defer { unacknowledged.cleanUp() }
        XCTAssertTrue(unacknowledged.controller.submit(prompt: "Begin", images: []))
        try unacknowledged.respond("thread/start", ["thread": unacknowledged.thread()])
        let turnStartID = try XCTUnwrap(try unacknowledged.request("turn/start")["id"] as? Int)
        unacknowledged.controller.expireServerRequest(turnStartID)

        XCTAssertFalse(unacknowledged.controller.isRunning)
        XCTAssertTrue(unacknowledged.controller.isRemoteTaskActive)
        XCTAssertFalse(unacknowledged.controller.canSubmit)
        XCTAssertFalse(unacknowledged.controller.submit(prompt: "Do not duplicate the work", images: []))
        XCTAssertEqual(unacknowledged.transport.requests("turn/start").count, 1)
        XCTAssertEqual(unacknowledged.controller.workbench.selectedTask?.state, .running)

        unacknowledged.controller.refreshSelectedTask()
        try unacknowledged.respond("thread/read", ["thread": unacknowledged.completedThread()])
        XCTAssertFalse(unacknowledged.controller.isRemoteTaskActive)
        XCTAssertTrue(unacknowledged.controller.canSubmit)
        XCTAssertTrue(unacknowledged.controller.submit(prompt: "Continue after checking", images: []))
        XCTAssertEqual(try unacknowledged.params("thread/resume")["threadId"] as? String, "thread-1")
    }

    func testWriterConflictRejectsOnlyFollowupAndPreservesExistingTranscript() throws {
        let cached = [WorkActivity(kind: .message, title: "Codex", detail: "Existing answer", turnID: "previous-turn")]
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", cachedActivities: cached, lastKnownTurnID: "previous-turn")
        defer { fixture.cleanUp() }
        let before = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        let attachment = ConversationImageAsset(data: Data([1, 2]), mimeType: "image/png", fileName: "evidence.png")
        XCTAssertTrue(fixture.controller.submit(prompt: "Follow up", images: [attachment]))
        let request = try fixture.request("thread/resume")
        let count = fixture.transport.messages.count
        let failure: [String: Any] = ["id": try XCTUnwrap(request["id"]),
            "error": ["code": -32000, "message": "thread thread-1 already has an active writer"]]
        fixture.controller.receiveServerMessage(failure)
        fixture.controller.receiveServerMessage(failure)

        XCTAssertFalse(fixture.controller.isRunning)
        XCTAssertFalse(fixture.controller.isTaskStatusUncertain)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, before.state)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.lastKnownTurnID, before.lastKnownTurnID)
        XCTAssertEqual(fixture.controller.activities, cached)
        XCTAssertEqual(fixture.controller.latestAgentMessage, before.latestAgentMessage)
        XCTAssertEqual(fixture.transport.messages.count, count, "Never retry or take over another writer automatically")
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
        let draft = try XCTUnwrap(fixture.controller.recoverableDrafts.first)
        XCTAssertEqual(fixture.controller.recoverableDrafts.count, 1)
        XCTAssertEqual(draft.prompt, "Follow up")
        XCTAssertEqual(draft.attachments, [attachment])
        XCTAssertEqual(draft.threadID, "thread-1")
        XCTAssertEqual(draft.recoveryTitle, "Message not sent")
        let restored = ComposerDraftStore(rootURL: fixture.controller.composerDraftStore.rootURL)
        XCTAssertTrue(try XCTUnwrap(restored.recoveries.first).hasWriterConflict)

        XCTAssertTrue(fixture.controller.restoreRecoveredDraft(draft))
        XCTAssertEqual(fixture.controller.composerDraftStore.draft(for: fixture.controller.composerDraftKey).attachments, [attachment])
        try fixture.respond("thread/read", ["thread": fixture.completedThread()])
        XCTAssertTrue(fixture.controller.submit(prompt: "Follow up", images: [attachment]))
        XCTAssertEqual(try fixture.params("thread/resume")["threadId"] as? String, "thread-1")
        try fixture.respond("thread/resume", ["thread": fixture.thread()])
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
    }

    func testUncertainTransportFailureIsNotPresentedAsWriterRejection() {
        let draft = CodexSubmissionDraft(prompt: "Question", attachments: [], error: "Connection closed")
        XCTAssertFalse(draft.hasWriterConflict)
        XCTAssertEqual(draft.recoveryTitle, "Message wasn’t confirmed")
        XCTAssertEqual(draft.recoveryExplanation, "Connection closed")
    }

    func testFailedThreadOrTurnStartPreservesThePromptAndEveryAttachmentAsOneDraft() throws {
        for failedMethod in ["thread/start", "thread/resume", "turn/start"] {
            let fixture = try WorkspaceFixture(restoredThreadID: failedMethod == "thread/resume" ? "thread-1" : nil)
            defer { fixture.cleanUp() }
            let prompt = "Keep this request when \(failedMethod) fails"
            let attachments = [
                ConversationImageAsset(data: Data([9, 8, 7]), mimeType: "image/png", fileName: "evidence.png"),
                ConversationImageAsset(data: Data("name,value\nalpha,42".utf8), mimeType: "text/csv", fileName: "source.csv")
            ]
            XCTAssertTrue(fixture.controller.submit(prompt: prompt, images: attachments))
            if failedMethod == "turn/start" {
                try fixture.respond("thread/start", ["thread": fixture.thread()])
            }
            XCTAssertTrue(fixture.controller.recoverableDrafts.isEmpty)
            let request = try fixture.request(failedMethod)
            let failure: [String: Any] = ["id": try XCTUnwrap(request["id"]), "error": ["code": -32000, "message": "Submission rejected"]]
            let sentCount = fixture.transport.messages.count

            fixture.controller.receiveServerMessage(failure)
            fixture.controller.receiveServerMessage(failure)

            XCTAssertEqual(fixture.controller.recoverableDrafts.count, 1, failedMethod)
            let draft = try XCTUnwrap(fixture.controller.recoverableDrafts.first)
            XCTAssertEqual(draft.prompt, prompt)
            XCTAssertEqual(draft.attachments, attachments)
            XCTAssertEqual(draft.workspaceID, fixture.controller.workbench.selectedWorkspaceID)
            XCTAssertEqual(draft.threadID, failedMethod == "thread/start" ? nil : "thread-1")
            XCTAssertEqual(draft.error, "Submission rejected")
            XCTAssertFalse(fixture.controller.isRunning)
            XCTAssertEqual(fixture.transport.messages.count, sentCount, "A failed submission must not resend itself")

            fixture.controller.discardRecoverableDraft(draft.id)
            XCTAssertTrue(fixture.controller.recoverableDrafts.isEmpty)
            XCTAssertEqual(fixture.transport.messages.count, sentCount)
        }
    }

    func testOutOfOrderSteerFailureRecoversOnlyItsDraftWhileTheOriginalTurnRuns() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let firstImage = ConversationImageAsset(data: Data([1]), mimeType: "image/png", fileName: "accepted.png")
        let secondImage = ConversationImageAsset(data: Data([2, 3]), mimeType: "image/png", fileName: "rejected.png")
        XCTAssertTrue(fixture.controller.submit(prompt: "First addition", images: [firstImage]))
        let acceptedRequest = try fixture.request("turn/steer")
        XCTAssertTrue(fixture.controller.submit(prompt: "Second addition", images: [secondImage]))
        let rejectedRequest = try fixture.request("turn/steer")
        let sentCount = fixture.transport.messages.count
        let failure: [String: Any] = ["id": try XCTUnwrap(rejectedRequest["id"]), "error": ["code": -32000, "message": "Steer rejected"]]

        fixture.controller.receiveServerMessage(failure)
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(acceptedRequest["id"]), "result": ["turnId": "turn-1"]])
        fixture.controller.receiveServerMessage(failure)

        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.canSteer)
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.state, .running)
        XCTAssertEqual(fixture.controller.recoverableDrafts.count, 1)
        let draft = try XCTUnwrap(fixture.controller.recoverableDrafts.first)
        XCTAssertEqual(draft.prompt, "Second addition")
        XCTAssertEqual(draft.attachments, [secondImage])
        XCTAssertEqual(draft.threadID, "thread-1")
        XCTAssertEqual(draft.error, "Steer rejected")
        XCTAssertEqual(fixture.controller.capabilityErrors["turn/steer"], "Steer rejected")
        XCTAssertEqual(fixture.transport.messages.count, sentCount)
        XCTAssertEqual(fixture.transport.requests("turn/start").count, 1)
    }

    func testDefaultCapabilityDiscoveryDoesNotRequestAppsAndHTMLFailureStaysIsolated() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshCapabilities()
        XCTAssertTrue(fixture.transport.requests("app/list").isEmpty)
        XCTAssertTrue(fixture.transport.requests("plugin/list").isEmpty)
        try fixture.respond("skills/list", ["data": [["skills": [["name": "reader", "path": "/tmp/reader/SKILL.md", "enabled": true]]]]])
        fixture.controller.refreshApps()
        let html = "HTTP 403 Forbidden <!DOCTYPE html><html><body>Account access details</body></html>"
        try fixture.fail("app/list", html)
        XCTAssertEqual(fixture.controller.skills.count, 1)
        XCTAssertNil(fixture.controller.capabilityErrors["skills/list"])
        XCTAssertEqual(fixture.controller.capabilityDiagnostics["app/list"], html)
        XCTAssertFalse(try XCTUnwrap(fixture.controller.capabilityErrors["app/list"]).contains("<html>"))
        fixture.controller.refreshSkills()
        XCTAssertEqual(fixture.transport.requests("app/list").count, 1)
        XCTAssertNotNil(fixture.controller.capabilityErrors["app/list"])
        XCTAssertTrue(fixture.controller.loadingCapabilityMethods.contains("skills/list"))
    }

    func testSkillReferencesAreMessageScopedAndAmbiguousNamesNeedAPath() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshSkills()
        try fixture.respond("skills/list", ["data": [["skills": [
            ["name": "reader", "path": "/tmp/a/SKILL.md", "enabled": true],
            ["name": "reader", "path": "/tmp/b/SKILL.md", "enabled": true]
        ]]]])
        XCTAssertFalse(fixture.controller.submit(prompt: "Use $reader", images: []))
        XCTAssertTrue(fixture.controller.statusMessage.contains("Multiple skills"))
        XCTAssertTrue(fixture.transport.requests("thread/start").isEmpty)
        let chosen = try XCTUnwrap(fixture.controller.skills.last)
        fixture.controller.bindSkillMention(chosen)
        XCTAssertTrue(fixture.controller.submit(prompt: "Use $reader", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let first = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertEqual(first.first { $0["type"] as? String == "skill" }?["path"] as? String, chosen.path)
        XCTAssertTrue(fixture.controller.selectedSkillPaths.isEmpty)
        try fixture.respond("turn/start", ["turn": ["id": "turn-1"]])
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.submit(prompt: "Continue normally", images: []))
        let second = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertFalse(second.contains { $0["type"] as? String == "skill" })
    }

    func testSelectingSkillWithoutMentionDoesNotAddAnImplicitInput() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshSkills()
        try fixture.respond("skills/list", ["data": [["skills": [["name": "reader", "path": "/tmp/reader/SKILL.md", "enabled": true]]]]])
        fixture.controller.bindSkillMention(try XCTUnwrap(fixture.controller.skills.first))
        XCTAssertTrue(fixture.controller.submit(prompt: "Plain message", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let input = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertFalse(input.contains { $0["type"] as? String == "skill" })
    }

    func testFileSearchUsesWorkspaceRootIgnoresStaleResponseAndExpandsQuotedPathInText() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.searchFiles(query: "old")
        let stale = try fixture.request("fuzzyFileSearch")
        fixture.controller.searchFiles(query: "read me")
        XCTAssertEqual(try fixture.params("fuzzyFileSearch")["roots"] as? [String], [fixture.directory.path])
        try fixture.respond("fuzzyFileSearch", ["files": [["root": fixture.directory.path, "path": "docs/read me.md", "file_name": "read me.md", "match_type": "file", "score": 21]]])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(stale["id"]), "result": ["files": []]])
        let file = try XCTUnwrap(fixture.controller.fileSearchResults.first)
        XCTAssertEqual(file.displayPath, "docs/read me.md")
        XCTAssertEqual(file.path, fixture.directory.appendingPathComponent("docs/read me.md").path)
        fixture.controller.bindFileMention(path: file.path)
        XCTAssertTrue(fixture.controller.submit(prompt: "Read @\"docs/read me.md\"", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let input = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, "Read \"\(file.path)\"")
        XCTAssertFalse(input.contains { $0["type"] as? String == "mention" })
        XCTAssertFalse(fixture.controller.isSearchingFiles)
    }

    func testExplicitPluginAndAppReferencesUseMentionInputsAndStayOutOfUnrelatedMessages() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let plugin = CodexExtensionEntry(id: "Plugin:docs@test", name: "Documents", kind: "Plugin",
            enabled: true, installed: true, rawPluginID: "docs@test")
        let app = CodexExtensionEntry(id: "App:calendar-id", name: "Google Calendar", kind: "App", status: "Available", enabled: true)
        XCTAssertEqual(fixture.controller.bindExtensionMention(plugin), "Documents")
        XCTAssertEqual(fixture.controller.bindExtensionMention(app), "Google Calendar")
        XCTAssertTrue(fixture.controller.submit(prompt: "Use @Documents with @\"Google Calendar\" and @Documents", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let inputs = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertEqual(inputs.filter { $0["type"] as? String == "mention" }.compactMap { $0["path"] as? String },
                       ["plugin://docs@test", "app://calendar-id"])
        try fixture.respond("turn/start", ["turn": ["id": "turn-1"]])
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.submit(prompt: "Continue normally", images: []))
        let next = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertFalse(next.contains { $0["type"] as? String == "mention" })
    }

    func testUnavailableExtensionsCannotBeSelectedAndUnboundTextDoesNotAttachTools() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let unavailable = CodexExtensionEntry(id: "Plugin:docs@test", name: "Documents", kind: "Plugin",
            enabled: false, installed: true, rawPluginID: "docs@test")
        XCTAssertNil(fixture.controller.bindExtensionMention(unavailable))
        XCTAssertTrue(fixture.controller.submit(prompt: "Use @Documents", images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let inputs = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertFalse(inputs.contains { $0["type"] as? String == "mention" })
    }

    func testUnknownSlashIsNeverSubmittedAsModelPrompt() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.controller.submit(prompt: "/future unsupported", images: []))
        XCTAssertTrue(fixture.transport.messages.isEmpty)
        XCTAssertTrue(fixture.controller.commandOutput.contains("not a runtime command"))
        XCTAssertFalse(fixture.controller.executeSlashCommand("/compact"))
        XCTAssertTrue(fixture.transport.messages.isEmpty)
    }

    func testPlanAndGoalUseDistinctRuntimeAPIsWithExplicitUserProvenance() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/plan"))
        XCTAssertTrue(fixture.transport.messages.isEmpty)
        XCTAssertEqual(fixture.controller.collaborationModes.first { $0.id == fixture.controller.selectedCollaborationModeID }?.mode, "plan")
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal Finish the migration --token-budget 1000"))
        XCTAssertFalse(fixture.controller.canSubmit)
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let params = try fixture.params("thread/goal/set")
        XCTAssertEqual(params["objective"] as? String, "Finish the migration --token-budget 1000")
        XCTAssertNil(params["tokenBudget"])
        XCTAssertEqual(params["origin"] as? String, "user")
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
        try fixture.respond("thread/goal/set", ["goal": ["threadId": "thread-1", "objective": "Finish the migration --token-budget 1000", "status": "active", "tokensUsed": 0]])
        XCTAssertEqual(fixture.controller.threadGoal?.objective, "Finish the migration --token-budget 1000")
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal pause"))
        XCTAssertEqual(try fixture.params("thread/goal/set")["status"] as? String, "paused")
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal clear"))
        XCTAssertEqual(try fixture.params("thread/goal/clear")["origin"] as? String, "user")
        try fixture.respond("thread/goal/clear", [:])
        XCTAssertNil(fixture.controller.threadGoal)
    }

    func testCommandStatusDoesNotReplaceAnActiveTurnAndGoalErrorsAreLocal() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        XCTAssertTrue(fixture.controller.executeSlashCommand("/status"))
        try fixture.respond("thread/read", ["thread": fixture.thread()])
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.canSteer)
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal pause"))
        try fixture.fail("thread/goal/set", "Goal is unavailable")
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.commandOutput.contains("Goal is unavailable"))
    }

    func testReviewAndCompactUseRuntimeLifecycleAndCannotSteer() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/review base main"))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let target = try XCTUnwrap(try fixture.params("review/start")["target"] as? [String: Any])
        XCTAssertEqual(target["type"] as? String, "baseBranch")
        XCTAssertEqual(target["branch"] as? String, "main")
        try fixture.respond("review/start", ["reviewThreadId": "thread-1", "turn": ["id": "review-1"]])
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertFalse(fixture.controller.canSteer)
        fixture.notify("turn/completed", ["turn": ["id": "review-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.executeSlashCommand("/compact"))
        XCTAssertEqual(try fixture.params("thread/compact/start")["threadId"] as? String, "thread-1")
        XCTAssertTrue(fixture.controller.isRunning)
        try fixture.respond("thread/compact/start", [:])
        fixture.notify("thread/compacted", [:])
        XCTAssertFalse(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testCommandPreparingThreadCannotOverwriteANewTask() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal First objective"))
        let old = try fixture.request("thread/start")
        fixture.controller.startNewTask()
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(old["id"]), "result": ["thread": fixture.thread()]])
        XCTAssertNil(fixture.controller.workbench.selectedTask)
        XCTAssertTrue(fixture.transport.requests("thread/goal/set").isEmpty)
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testStatusOfSavedThreadIsReadOnlyAndDoesNotResumeIt() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/status"))
        XCTAssertEqual(try fixture.params("thread/read")["includeTurns"] as? Bool, false)
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        try fixture.respond("thread/read", ["thread": fixture.thread()])
        XCTAssertTrue(fixture.controller.commandOutput.contains("thread-1"))
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testGoalActivationBlocksDuplicateSubmissionUntilRuntimeStartsAndUnsupportedGoalIsLocal() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal Finish task"))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        XCTAssertFalse(fixture.controller.canSubmit)
        try fixture.fail("thread/goal/set", "goals feature is disabled")
        XCTAssertTrue(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.controller.commandOutput.contains("goals feature is disabled"))
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal Finish task"))
        try fixture.respond("thread/goal/set", ["goal": ["threadId": "thread-1", "objective": "Finish task", "status": "active"]])
        XCTAssertFalse(fixture.controller.canSubmit)
        XCTAssertTrue(fixture.transport.requests("turn/start").isEmpty)
        fixture.notify("turn/started", ["turn": ["id": "goal-turn"]])
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.canSteer)
        fixture.notify("turn/completed", ["turn": ["id": "goal-turn", "status": "completed"]])
        XCTAssertTrue(fixture.controller.canSubmit)
    }

    func testStoppingReviewBeforeReplyWaitsForItsRealTurnID() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/review"))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        fixture.controller.interrupt()
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.transport.requests("turn/interrupt").isEmpty)
        try fixture.respond("review/start", ["reviewThreadId": "thread-1", "turn": ["id": "review-turn"]])
        XCTAssertEqual(try fixture.params("turn/interrupt")["turnId"] as? String, "review-turn")
        fixture.notify("turn/completed", ["turn": ["id": "review-turn", "status": "interrupted"]])
        XCTAssertFalse(fixture.controller.isRunning)
    }

    func testSkillsChangedCoalescesRefreshAndDoesNotWaitForApps() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshSkills()
        fixture.controller.refreshApps()
        fixture.notify("skills/changed", [:])
        fixture.notify("skills/changed", [:])
        XCTAssertEqual(fixture.transport.requests("skills/list").count, 1)
        try fixture.respond("skills/list", ["data": []])
        XCTAssertEqual(fixture.transport.requests("skills/list").count, 2)
        XCTAssertEqual(fixture.transport.requests("app/list").count, 1)
        try fixture.respond("skills/list", ["data": []])
        XCTAssertFalse(fixture.controller.loadingCapabilityMethods.contains("skills/list"))
        XCTAssertTrue(fixture.controller.loadingCapabilityMethods.contains("app/list"))
    }

    func testPlanOffIsLiteralPromptAndGoalStatusIsLiteralObjective() throws {
        let plan = try WorkspaceFixture()
        defer { plan.cleanUp() }
        XCTAssertTrue(plan.controller.executeSlashCommand("/plan off"))
        try plan.respond("thread/start", ["thread": plan.thread()])
        let turn = try plan.params("turn/start")
        XCTAssertEqual((turn["collaborationMode"] as? [String: Any])?["mode"] as? String, "plan")
        XCTAssertEqual((turn["input"] as? [[String: Any]])?.first?["text"] as? String, "off")

        let goal = try WorkspaceFixture()
        defer { goal.cleanUp() }
        XCTAssertTrue(goal.controller.executeSlashCommand("/goal status"))
        try goal.respond("thread/start", ["thread": goal.thread()])
        XCTAssertEqual(try goal.params("thread/goal/set")["objective"] as? String, "status")
        XCTAssertNil(try goal.params("thread/goal/set")["tokenBudget"])
        XCTAssertTrue(goal.transport.requests("thread/goal/get").isEmpty)
    }

    func testPausingOrClearingSavedGoalDoesNotResumeAndReactivateIt() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal pause"))
        XCTAssertEqual(try fixture.params("thread/goal/set")["status"] as? String, "paused")
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        try fixture.respond("thread/goal/set", ["goal": ["threadId": "thread-1", "objective": "Saved objective", "status": "paused"]])
        XCTAssertTrue(fixture.controller.executeSlashCommand("/goal clear"))
        XCTAssertEqual(try fixture.params("thread/goal/clear")["origin"] as? String, "user")
        XCTAssertTrue(fixture.transport.requests("thread/resume").isEmpty)
        XCTAssertFalse(fixture.controller.isRunning)
    }

    func testGoalEditorTreatsReservedWordsAsLiteralObjectivesAndRejectsEmptyInput() throws {
        for objective in ["pause", "resume", "clear", "edit", "status"] {
            let fixture = try WorkspaceFixture()
            defer { fixture.cleanUp() }
            XCTAssertFalse(fixture.controller.setThreadGoal(objective: " \n "))
            XCTAssertTrue(fixture.transport.messages.isEmpty)
            XCTAssertTrue(fixture.controller.setThreadGoal(objective: objective))
            try fixture.respond("thread/start", ["thread": fixture.thread()])
            let params = try fixture.params("thread/goal/set")
            XCTAssertEqual(params["objective"] as? String, objective)
            XCTAssertEqual(params["status"] as? String, "active")
            XCTAssertEqual(params["origin"] as? String, "user")
            XCTAssertTrue(fixture.transport.requests("thread/goal/clear").isEmpty)
            XCTAssertTrue(fixture.transport.requests("thread/goal/get").isEmpty)
        }
    }

    func testInlineNewTaskCanPreserveOnlyItsComposerSkillBinding() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshSkills()
        try fixture.respond("skills/list", ["data": [["skills": [
            ["name": "reader", "path": "/tmp/a/SKILL.md", "enabled": true],
            ["name": "reader", "path": "/tmp/b/SKILL.md", "enabled": true]
        ]]]])
        let selected = try XCTUnwrap(fixture.controller.skills.last)
        fixture.controller.bindSkillMention(selected)
        fixture.controller.startNewTask(preservingComposerBindings: true)
        XCTAssertEqual(fixture.controller.selectedSkillPaths, [selected.path])
        let sourceKey = fixture.controller.composerDraftKey
        XCTAssertTrue(fixture.controller.submit(prompt: "Use $reader", images: []))
        XCTAssertTrue(fixture.controller.composerDraftStore.draft(for: sourceKey).isEmpty,
            "A binding-only draft supplied to a new task must be consumed with its submission")
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let input = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertEqual(input.first { $0["type"] as? String == "skill" }?["path"] as? String, selected.path)
        XCTAssertTrue(fixture.controller.selectedSkillPaths.isEmpty)
        try fixture.respond("turn/start", ["turn": ["id": "turn-1"]])
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        fixture.controller.bindSkillMention(selected)
        fixture.controller.startNewTask()
        XCTAssertTrue(fixture.controller.selectedSkillPaths.isEmpty)
    }

    func testInlinePlanPreservesImageAndDocumentAttachmentsThroughSubmissionFailure() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let image = ConversationImageAsset(data: Data([1, 2, 3]), mimeType: "image/png", fileName: "plan.png")
        let document = ConversationImageAsset(data: Data("name,value\nA,3".utf8), mimeType: "text/csv", fileName: "notes.csv")
        XCTAssertTrue(fixture.controller.executeSlashCommand("/plan Check these references", images: [image, document]))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let params = try fixture.params("turn/start")
        XCTAssertEqual((params["collaborationMode"] as? [String: Any])?["mode"] as? String, "plan")
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        let imagePath = try XCTUnwrap(input.first { $0["type"] as? String == "localImage" }?["path"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)), image.data)
        XCTAssertTrue(input.contains { ($0["text"] as? String)?.contains("notes.csv") == true })
        try fixture.fail("turn/start", "Plan start failed")
        let restored = try XCTUnwrap(fixture.controller.recoverableDrafts.first)
        XCTAssertEqual(restored.prompt, "Check these references")
        XCTAssertEqual(restored.attachments, [image, document])
    }

    func testReviewAndGoalCommandFailuresRecoverOriginalSlashDraftAcrossPreparation() throws {
        for command in ["/review Examine the migration carefully", "/goal Finish the migration carefully"] {
            for failure in ["thread/start", "thread/resume", "command"] {
                let fixture = try WorkspaceFixture(restoredThreadID: failure == "thread/resume" ? "thread-1" : nil)
                defer { fixture.cleanUp() }
                let attachment = ConversationImageAsset(data: Data("context".utf8), mimeType: "text/csv", fileName: "context.csv")
                XCTAssertTrue(fixture.controller.executeSlashCommand(command, images: [attachment]))
                let method = command.hasPrefix("/review") ? "review/start" : "thread/goal/set"
                if failure == "command" { try fixture.respond("thread/start", ["thread": fixture.thread()]) }
                let failingMethod = failure == "command" ? method : failure
                let failedRequest = try fixture.request(failingMethod)
                try fixture.fail(failingMethod, "Command failed")
                fixture.controller.receiveServerMessage(["id": try XCTUnwrap(failedRequest["id"]), "error": ["message": "Duplicate failure"]])
                XCTAssertEqual(fixture.controller.recoverableDrafts.count, 1)
                let draft = try XCTUnwrap(fixture.controller.recoverableDrafts.first)
                XCTAssertEqual(draft.prompt, command)
                XCTAssertEqual(draft.attachments, [attachment])
                XCTAssertEqual(draft.error, "Command failed")
            }
        }
    }

    func testConfirmedReviewDoesNotRecoverAnAcceptedCommandAfterResponseTimeout() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.executeSlashCommand("/review Check the changes"))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let requestID = try XCTUnwrap(try fixture.request("review/start")["id"] as? Int)
        fixture.notify("turn/started", ["turn": ["id": "review-turn"]])
        fixture.controller.expireServerRequest(requestID)
        fixture.notify("turn/completed", ["turn": ["id": "review-turn", "status": "completed"]])
        fixture.controller.setAppServerURL("ws://127.0.0.1:4567")
        XCTAssertTrue(fixture.controller.recoverableDrafts.isEmpty)
    }

    func testCodeAndUnboundSigilsRemainLiteralWhileQuotedFileBindingIsDecoded() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshSkills()
        try fixture.respond("skills/list", ["data": [["skills": [["name": "reader", "path": "/tmp/reader/SKILL.md", "enabled": true]]]]])
        let path = fixture.directory.appendingPathComponent("a\"b.swift").path
        fixture.controller.bindFileMention(path: path)
        let quoted = AgentComposerCandidate.file(path: path, displayPath: "a\"b.swift").insertion
        let ordinary = "Explain `@MainActor` and `$reader`.\n```swift\n@MainActor let value = $reader\n```\nKeep $unknown and @unknown-handle. Read "
        XCTAssertTrue(fixture.controller.submit(prompt: ordinary + quoted, images: []))
        try fixture.respond("thread/start", ["thread": fixture.thread()])
        let input = try XCTUnwrap(try fixture.params("turn/start")["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["text"] as? String, ordinary + String(reflecting: path))
        XCTAssertFalse(input.contains { $0["type"] as? String == "skill" || $0["type"] as? String == "mention" })
    }

    func testOldGoalReadsCannotOverwriteMutationsOrNewNotifications() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.refreshThreadGoal())
        let staleRead = try fixture.request("thread/goal/get")
        XCTAssertTrue(fixture.controller.setThreadGoal(objective: "New objective"))
        try fixture.respond("thread/resume", ["thread": fixture.thread()])
        try fixture.respond("thread/goal/set", ["goal": ["threadId": "thread-1", "objective": "New objective", "status": "active"]])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(staleRead["id"]), "result": ["goal": ["threadId": "thread-1", "objective": "Old objective", "status": "paused"]]])
        XCTAssertEqual(fixture.controller.threadGoal?.objective, "New objective")
        XCTAssertTrue(fixture.controller.refreshThreadGoal())
        let beforeNotification = try fixture.request("thread/goal/get")
        fixture.notify("thread/goal/updated", ["goal": ["threadId": "thread-1", "objective": "Latest objective", "status": "active"]])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(beforeNotification["id"]), "result": ["goal": ["threadId": "thread-1", "objective": "Old objective", "status": "paused"]]])
        XCTAssertEqual(fixture.controller.threadGoal?.objective, "Latest objective")
        XCTAssertNil(try fixture.params("thread/goal/get")["_goalReadRevision"])
    }

    func testGlobalHistoryIncludesIndependentWorkingDirectoriesAndArchivedThreads() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.loadAllTaskHistory()
        XCTAssertNil(try fixture.params("thread/list")["cwd"])
        let liveDirectory = fixture.directory.appendingPathComponent("worktree").path
        try fixture.respond("thread/list", ["data": [fixture.thread(id: "worktree-thread", cwd: liveDirectory)], "nextCursor": "threads-page-2"])
        XCTAssertEqual(try fixture.params("thread/list")["cursor"] as? String, "threads-page-2")
        try fixture.respond("thread/list", ["data": []])
        XCTAssertEqual(try fixture.params("thread/list")["archived"] as? Bool, true)
        try fixture.respond("thread/list", ["data": [fixture.thread(id: "archived-thread")]])

        XCTAssertFalse(fixture.controller.isLoadingTaskHistory)
        let liveTask = try XCTUnwrap(fixture.controller.workbench.tasks.first { $0.threadID == "worktree-thread" })
        XCTAssertEqual(fixture.controller.workbench.workspaces.first { $0.id == liveTask.workspaceID }?.path, liveDirectory)
        let archivedTask = try XCTUnwrap(fixture.controller.workbench.tasks.first { $0.threadID == "archived-thread" })
        XCTAssertTrue(fixture.controller.workbench.isTaskArchived(archivedTask.id))
        XCTAssertFalse(fixture.controller.savedTasks.contains { $0.id == archivedTask.id })
    }

    func testStaleReadResponseCannotReplaceTheNewlySelectedTask() throws {
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1")
        defer { fixture.cleanUp() }
        fixture.controller.refreshSelectedTask()
        let oldRead = try fixture.request("thread/read")
        let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
        let task = fixture.controller.workbench.upsertRemoteTask(
            workspaceID: workspaceID, threadID: "thread-2", title: "Second task", state: .completed,
            statusMessage: "Ready", createdAt: Date(), updatedAt: Date())
        fixture.controller.selectTask(task)
        try fixture.respond("thread/read", ["thread": fixture.thread(id: "thread-2")])

        var stale = fixture.thread()
        stale["turns"] = [["id": "old-turn", "items": [["id": "old-answer", "type": "agentMessage", "text": "Stale answer"]]]]
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldRead["id"]), "result": ["thread": stale]])

        XCTAssertEqual(fixture.controller.workbench.selectedTask?.threadID, "thread-2")
        XCTAssertFalse(fixture.controller.activities.contains { $0.detail == "Stale answer" })
        XCTAssertFalse(fixture.controller.isReadingSelectedTask)
        XCTAssertTrue(fixture.controller.canSubmit)
    }
}

extension CodexWorkspaceTests {
    func testRenameSelectedTaskCommitsOnlyAfterACKAndDoesNotInterruptTheTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let original = try XCTUnwrap(fixture.controller.workbench.selectedTask)
        XCTAssertTrue(fixture.controller.renameSelectedTask("New title"))
        XCTAssertTrue(fixture.controller.isRenamingTask)
        XCTAssertFalse(fixture.controller.renameSelectedTask("Duplicate"))
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.title, original.title)
        let params = try fixture.params("thread/name/set")
        XCTAssertEqual(params["threadId"] as? String, "thread-1")
        XCTAssertEqual(params["name"] as? String, "New title")
        XCTAssertNil(params["_localTaskID"])
        try fixture.fail("thread/name/set", "Rename rejected")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.title, original.title)
        XCTAssertFalse(fixture.controller.isRenamingTask)
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.controller.executeSlashCommand("/rename Accepted title"))
        try fixture.respond("thread/name/set", [:])
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.title, "Accepted title")
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.id, original.id)
        XCTAssertNil(fixture.controller.capabilityErrors["thread/name/set"])
        XCTAssertFalse(fixture.controller.isRenamingTask)
        XCTAssertTrue(fixture.controller.isRunning)
    }

    func testRenameLocalTaskAndPinDoNotSendRemoteRequests() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.controller.renameSelectedTask("No selected chat"))
        let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
        let task = fixture.controller.workbench.createTask(workspaceID: workspaceID, prompt: "Local draft")
        fixture.controller.selectTask(task)
        XCTAssertTrue(fixture.controller.canRenameSelectedTask)
        XCTAssertFalse(fixture.controller.canForkSelectedTask)
        XCTAssertTrue(fixture.controller.executeSlashCommand("/rename Local name"))
        fixture.controller.toggleTaskPinned(task)
        XCTAssertEqual(fixture.controller.pinnedTaskIDs, [task.id])
        XCTAssertEqual(fixture.controller.savedTasks.first?.title, "Local name")
        XCTAssertTrue(fixture.transport.requests("thread/name/set").isEmpty)
        XCTAssertTrue(fixture.transport.requests("thread/start").isEmpty)
    }

    func testWorkspacePinActionWorksDuringActiveTurnAndDesktopSync() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        let controller = fixture.controller
        let selected = try XCTUnwrap(controller.workbench.selectedWorkspace)
        controller.workbench.importProjects([["id": "shared-project", "name": selected.name,
            "roots": [["path": selected.path]]]])
        let snapshot = CodexDesktopSidebarSnapshot(projects: [], projectOrder: ["shared-project"],
            pinnedProjectIDs: [], taskOrder: [:], chatSort: "manual", projectSort: "manual", grouping: "project")
        controller.workbench.applyDesktopSidebarPreferences(snapshot)
        controller.toggleWorkspacePinned(selected)
        XCTAssertTrue(controller.savedWorkspaces.first { $0.id == selected.id }?.isPinned == true)
        XCTAssertTrue(controller.isRunning, "Pinning must not interrupt the active turn")
        controller.workbench.applyDesktopSidebarPreferences(snapshot)
        XCTAssertTrue(controller.workbench.selectedWorkspace?.isPinned == true)
        controller.toggleWorkspacePinned(selected)
        XCTAssertFalse(try XCTUnwrap(controller.savedWorkspaces.first { $0.id == selected.id }).isPinned)
        controller.followDesktopWorkspacePin(selected)
        XCTAssertNil(controller.workbench.selectedWorkspace?.pinOverride)
        XCTAssertTrue(fixture.transport.requests("project/update").isEmpty,
            "Local project pins must not claim to write unsupported desktop state")
    }

    func testRenameLateReplyCannotRenameAnotherSelectedTask() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.notify("turn/completed", ["turn": ["id": "turn-1", "status": "completed"]])
        XCTAssertTrue(fixture.controller.renameSelectedTask("Old task rename"))
        let oldRequest = try fixture.request("thread/name/set")
        let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
        let local = fixture.controller.workbench.createTask(workspaceID: workspaceID, prompt: "New local chat")
        fixture.controller.selectTask(local)
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldRequest["id"]), "result": [:]])
        XCTAssertEqual(fixture.controller.workbench.selectedTask?.title, "New local chat")
        XCTAssertFalse(fixture.controller.isRenamingTask)
    }

    func testChatTranscriptIncludesCompletedMessagesAndMarkdownAttachmentsOnly() throws {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Explain this file"],
            ["type": "localImage", "path": "/tmp/screen shot.png"],
            ["type": "text", "text": "Attached file: notes.csv (text/csv)\nLocal path: /tmp/notes.csv"],
            ["type": "image", "url": "data:image/png;base64,DO_NOT_COPY_BASE64"],
            ["type": "skill", "name": "reader"],
            ["type": "mention", "name": "Calendar"],
            ["type": "unknown", "privateData": "DO_NOT_COPY_UNKNOWN"]
        ]
        let raw = CodexProtocolJSON.pretty(["type": "userMessage", "content": content])
        let cached = [
            WorkActivity(kind: .user, title: "You", detail: "fallback", rawJSON: raw),
            WorkActivity(kind: .command, title: "Tool", detail: "DO_NOT_COPY_TOOL", rawJSON: "DO_NOT_COPY_JSON"),
            WorkActivity(kind: .plan, title: "Plan", detail: "DO_NOT_COPY_PLAN"),
            WorkActivity(kind: .message, title: "Codex", detail: "Here is the **answer**."),
            WorkActivity(kind: .user, title: "You", detail: "Follow-up question"),
            WorkActivity(kind: .message, title: "Codex", detail: "Second answer"),
            WorkActivity(kind: .message, title: "Codex", detail: "DO_NOT_COPY_STREAM", isComplete: false)
        ]
        let fixture = try WorkspaceFixture(restoredThreadID: "thread-1", cachedActivities: cached)
        defer { fixture.cleanUp() }
        let transcript = fixture.controller.chatTranscript
        XCTAssertTrue(transcript.contains("## You\n\nExplain this file"))
        XCTAssertTrue(transcript.contains("![screen shot.png](</tmp/screen shot.png>)"))
        XCTAssertTrue(transcript.contains("[notes.csv](</tmp/notes.csv>)"))
        XCTAssertTrue(transcript.contains("## Codex\n\nHere is the **answer**."))
        XCTAssertTrue(transcript.contains("$reader\n\n@Calendar"))
        XCTAssertTrue(transcript.contains("Here is the **answer**.\n\n## You\n\nFollow-up question\n\n## Codex\n\nSecond answer"))
        XCTAssertFalse(transcript.contains("DO_NOT_COPY"))
        XCTAssertFalse(transcript.contains("fallback"))
    }

    private func settingsConfig(version: String = "user-v1", webSearch: String = "cached") -> [String: Any] {
        ["config": ["web_search": webSearch, "model_verbosity": "medium", "analytics": ["enabled": true]],
         "origins": ["web_search": ["name": ["type": "user", "file": "/tmp/mock-codex-config.toml"], "version": version]],
         "layers": [["name": ["type": "user", "file": "/tmp/mock-codex-config.toml"], "version": version, "config": [:]]]]
    }

    func testSettingsReadUsesCWDAndVersionsEveryWhitelistedWrite() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshConfiguration()
        XCTAssertEqual(try fixture.params("config/read")["includeLayers"] as? Bool, true)
        XCTAssertEqual(try fixture.params("config/read")["cwd"] as? String, fixture.directory.path)
        try fixture.respond("config/read", settingsConfig())
        XCTAssertFalse(fixture.controller.canWriteConfiguration)
        try fixture.respond("configRequirements/read", ["requirements": NSNull()])
        XCTAssertTrue(fixture.controller.canWriteConfiguration)
        XCTAssertFalse(fixture.controller.setConfigurationValue("sandbox_mode", value: "danger-full-access"))
        XCTAssertFalse(fixture.controller.setConfigurationValue("analytics.enabled", value: 1))
        XCTAssertTrue(fixture.transport.requests("config/value/write").isEmpty)
        XCTAssertTrue(fixture.controller.setConfigurationValue("web_search", value: "live"))
        let write = try fixture.params("config/value/write")
        XCTAssertEqual(write["expectedVersion"] as? String, "user-v1")
        XCTAssertEqual(write["filePath"] as? String, "/tmp/mock-codex-config.toml")
        XCTAssertEqual(write["mergeStrategy"] as? String, "replace")
        XCTAssertFalse(fixture.controller.setConfigurationValue("web_search", value: "disabled"))
        try fixture.respond("config/value/write", ["status": "ok", "version": "user-v2", "filePath": "/tmp/mock-codex-config.toml"])
        XCTAssertEqual(fixture.transport.requests("config/read").count, 2)
        try fixture.respond("config/read", settingsConfig(version: "user-v2", webSearch: "live"))
        try fixture.respond("configRequirements/read", ["requirements": NSNull()])
        XCTAssertTrue(fixture.controller.setConfigurationValue("model_verbosity", value: NSNull()))
        XCTAssertTrue(try fixture.params("config/value/write")["value"] is NSNull)
        XCTAssertEqual(try fixture.params("config/value/write")["expectedVersion"] as? String, "user-v2")
    }

    func testSettingsManagedRestrictionsAndVersionConflictsNeverForceOverwrite() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshConfiguration()
        try fixture.respond("config/read", settingsConfig())
        try fixture.respond("configRequirements/read", ["requirements": ["allowedWebSearchModes": ["disabled", "cached"]]])
        XCTAssertFalse(fixture.controller.setConfigurationValue("web_search", value: "live"))
        XCTAssertTrue(fixture.controller.setConfigurationValue("analytics.enabled", value: false))
        try fixture.fail("config/value/write", "Config version conflict")
        XCTAssertEqual(fixture.transport.requests("config/value/write").count, 1)
        XCTAssertFalse(fixture.controller.canWriteConfiguration)
        XCTAssertTrue(fixture.controller.configurationStatusMessage.contains("no conflict was overwritten"))
        XCTAssertNotNil(fixture.controller.settingsErrors["config/value/write"])
        fixture.controller.refreshConfiguration()
        try fixture.respond("config/read", settingsConfig(version: "latest"))
        try fixture.respond("configRequirements/read", ["requirements": NSNull()])
        XCTAssertTrue(fixture.controller.setConfigurationValue("model_verbosity", value: "high"))
        try fixture.respond("config/value/write", ["status": "okOverridden", "version": "new", "filePath": "/tmp/mock-codex-config.toml"])
        XCTAssertTrue(fixture.controller.configurationStatusMessage.contains("higher-priority"))
    }

    func testSettingsCannotWriteWithoutUserLayerOrWhileTaskIsRunning() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshConfiguration()
        try fixture.respond("config/read", ["config": [:], "origins": [:]])
        try fixture.respond("configRequirements/read", ["requirements": NSNull()])
        XCTAssertFalse(fixture.controller.canWriteConfiguration)
        fixture.controller.refreshConfiguration()
        try fixture.respond("config/read", settingsConfig())
        try fixture.respond("configRequirements/read", ["requirements": NSNull()])
        try fixture.startTurn()
        XCTAssertFalse(fixture.controller.setConfigurationValue("analytics.enabled", value: false))
        fixture.controller.startAccountLogin()
        fixture.controller.logoutAccount()
        XCTAssertTrue(fixture.transport.requests("account/login/start").isEmpty)
        XCTAssertTrue(fixture.transport.requests("account/logout").isEmpty)
        fixture.controller.refreshRateLimits()
        try fixture.fail("account/rateLimits/read", "403 <!doctype html><body>forbidden</body>")
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertEqual(fixture.controller.settingsErrors["account/rateLimits/read"], "Access denied (403). This capability is unavailable for the connected account.")
        XCTAssertNil(fixture.controller.capabilityErrors["account/rateLimits/read"])
    }

    func testSettingsSwitchingWorkspaceDropsStaleConfigurationAndFeatures() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshConfiguration()
        fixture.controller.refreshExperimentalFeatures()
        let oldConfig = try fixture.request("config/read")
        let oldFeatures = try fixture.request("experimentalFeature/list")
        let other = fixture.controller.workbench.ensureWorkspace(url: fixture.directory.appendingPathComponent("other"))
        fixture.controller.selectWorkspace(other)
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldConfig["id"]), "result": settingsConfig()])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldFeatures["id"]), "result": ["data": [["name": "old", "stage": "beta", "enabled": true, "defaultEnabled": false]]]])
        XCTAssertNil(fixture.controller.configuration)
        XCTAssertTrue(fixture.controller.experimentalFeatures.isEmpty)
        XCTAssertTrue(fixture.controller.settingsLoadingMethods.isEmpty)
    }

    func testAccountLoginCompletionUsesMatchingIDAndRefreshesAccountAndUsage() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.startAccountLogin()
        fixture.controller.startAccountLogin()
        XCTAssertEqual(fixture.transport.requests("account/login/start").count, 1)
        XCTAssertEqual(try fixture.params("account/login/start")["type"] as? String, "chatgpt")
        try fixture.respond("account/login/start", ["type": "chatgpt", "loginId": "mine", "authUrl": "https://auth.openai.com/login"])
        fixture.notify("account/login/completed", ["loginId": "other", "success": true])
        XCTAssertEqual(fixture.controller.accountLogin?.id, "mine")
        fixture.notify("account/login/completed", ["loginId": "mine", "success": true])
        XCTAssertNil(fixture.controller.accountLogin)
        XCTAssertEqual(fixture.transport.requests("account/read").count, 1)
        XCTAssertEqual(fixture.transport.requests("account/rateLimits/read").count, 1)
        XCTAssertEqual(fixture.transport.requests("account/usage/read").count, 1)
        try fixture.respond("account/read", ["account": ["type": "chatgpt", "email": "test@example.com", "planType": "plus"], "requiresOpenaiAuth": true])
        XCTAssertEqual(fixture.controller.account?.email, "test@example.com")
        XCTAssertEqual(fixture.controller.requiresOpenAIAuth, true)
    }

    func testModelRefreshAfterLoginDoesNotDiscardSettingsRequestsOrSuccessState() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        // Settings can be the first feature that connects to the selected runtime.
        fixture.controller.startAccountLogin()
        try fixture.respond("account/login/start", ["type": "chatgpt", "loginId": "mine", "authUrl": "https://auth.openai.com/login"])
        fixture.notify("account/login/completed", ["loginId": "mine", "success": true])
        let accountRequest = try fixture.request("account/read")
        let usageRequest = try fixture.request("account/usage/read")
        fixture.controller.refreshModels()
        XCTAssertEqual(fixture.controller.accountStatusMessage, "Sign-in completed.")
        XCTAssertTrue(fixture.controller.settingsLoadingMethods.contains("account/read"))
        XCTAssertTrue(fixture.controller.settingsLoadingMethods.contains("account/usage/read"))
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(accountRequest["id"]), "result": ["account": ["type": "chatgpt", "email": "test@example.com", "planType": "plus"], "requiresOpenaiAuth": true]])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(usageRequest["id"]), "result": ["summary": ["lifetimeTokens": 42]]])
        XCTAssertEqual(fixture.controller.account?.email, "test@example.com")
        XCTAssertEqual(fixture.controller.accountUsage?.lifetimeTokens, 42)
        try fixture.respond("model/list", ["data": []])
        fixture.controller.refreshModels()
        XCTAssertEqual(fixture.controller.account?.email, "test@example.com")
        XCTAssertEqual(fixture.controller.accountStatusMessage, "Sign-in completed.")
    }

    func testAccountDeviceLoginCancellationAndEarlyCompletion() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.startAccountLogin(deviceCode: true)
        XCTAssertEqual(try fixture.params("account/login/start")["type"] as? String, "chatgptDeviceCode")
        try fixture.respond("account/login/start", ["type": "chatgptDeviceCode", "loginId": "device", "verificationUrl": "https://auth.openai.com/device", "userCode": "ABCD"])
        XCTAssertEqual(fixture.controller.accountLogin?.userCode, "ABCD")
        fixture.controller.cancelAccountLogin()
        fixture.controller.cancelAccountLogin()
        XCTAssertEqual(fixture.transport.requests("account/login/cancel").count, 1)
        XCTAssertEqual(try fixture.params("account/login/cancel")["loginId"] as? String, "device")
        try fixture.respond("account/login/cancel", ["status": "canceled"])
        XCTAssertNil(fixture.controller.accountLogin)
        fixture.notify("account/login/completed", ["loginId": "device", "success": true])
        XCTAssertTrue(fixture.transport.requests("account/read").isEmpty)
        fixture.controller.startAccountLogin()
        fixture.notify("account/login/completed", ["loginId": "early", "success": true])
        try fixture.respond("account/login/start", ["type": "chatgpt", "loginId": "early", "authUrl": "https://auth.openai.com/login"])
        XCTAssertNil(fixture.controller.accountLogin)
        XCTAssertEqual(fixture.controller.accountStatusMessage, "Sign-in completed.")
    }

    func testAccountChangeDiscardsPendingAccountAndUsageResponsesAndLogoutResetsState() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshAccount()
        fixture.controller.refreshAccountUsage()
        let oldAccount = try fixture.request("account/read")
        let oldUsage = try fixture.request("account/usage/read")
        fixture.notify("account/updated", ["authMode": "chatgpt", "planType": "pro"])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldAccount["id"]), "result": ["account": ["type": "chatgpt", "email": "old@example.com", "planType": "plus"], "requiresOpenaiAuth": true]])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldUsage["id"]), "result": ["summary": ["lifetimeTokens": 999]]])
        XCTAssertNil(fixture.controller.account)
        XCTAssertNil(fixture.controller.accountUsage)
        try fixture.respond("account/read", ["account": ["type": "chatgpt", "email": "new@example.com", "planType": "pro"], "requiresOpenaiAuth": true])
        try fixture.respond("account/usage/read", ["summary": ["lifetimeTokens": 12], "dailyUsageBuckets": [["startDate": "2026-10-18", "tokens": 12]]])
        XCTAssertEqual(fixture.controller.accountUsage?.lifetimeTokens, 12)
        fixture.controller.logoutAccount()
        try fixture.respond("account/logout", [:])
        XCTAssertNil(fixture.controller.account)
        XCTAssertNil(fixture.controller.accountUsage)
        XCTAssertTrue(fixture.controller.rateLimitBuckets.isEmpty)
    }

    func testRateLimitsPreferMultipleBucketsAndSparseUpdatesClearExplicitNullWindows() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshRateLimits()
        try fixture.respond("account/rateLimits/read", ["ordinaryUsageAllowed": false,
            "rateLimits": ["limitId": "legacy", "primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": ["limitId": "codex", "planType": "plus", "primary": ["usedPercent": 20], "secondary": ["usedPercent": 30], "credits": ["balance": "4", "hasCredits": true, "unlimited": false]],
                "review": ["limitId": "review", "primary": ["usedPercent": 10]]]])
        XCTAssertEqual(fixture.controller.rateLimitBuckets.map(\.id), ["codex", "review"])
        fixture.notify("account/rateLimits/updated", ["rateLimits": ["limitId": "codex", "planType": NSNull(), "primary": NSNull(), "credits": NSNull()]])
        let codex = try XCTUnwrap(fixture.controller.rateLimitBuckets.first)
        XCTAssertNil(codex.primary)
        XCTAssertNil(codex.creditsBalance)
        XCTAssertEqual(codex.secondary?.usedPercent, 30)
        XCTAssertEqual(codex.planType, "plus", "Sparse nullable account metadata does not clear known metadata")
        XCTAssertEqual(fixture.controller.rateLimitBuckets.last?.primary?.usedPercent, 10)
        XCTAssertEqual(fixture.controller.ordinaryUsageAllowed, false)
    }

    func testRateLimitNotificationInvalidatesOlderReadResponse() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.refreshRateLimits()
        let oldRead = try fixture.request("account/rateLimits/read")
        fixture.notify("account/rateLimits/updated", ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 80]]])
        fixture.controller.receiveServerMessage(["id": try XCTUnwrap(oldRead["id"]), "result": ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 10]]]])
        XCTAssertEqual(fixture.controller.rateLimitBuckets.first?.primary?.usedPercent, 80)
        XCTAssertEqual(fixture.transport.requests("account/rateLimits/read").count, 2)
        XCTAssertTrue(fixture.controller.settingsLoadingMethods.contains("account/rateLimits/read"))
    }

    func testExperimentalFeaturesPaginateAndSettingsTimeoutDoesNotStopTheTurn() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        try fixture.startTurn()
        fixture.controller.refreshExperimentalFeatures()
        XCTAssertEqual(try fixture.params("experimentalFeature/list")["threadId"] as? String, "thread-1")
        try fixture.respond("experimentalFeature/list", ["data": [["name": "first", "stage": "beta", "enabled": true, "defaultEnabled": false]], "nextCursor": "page2"])
        XCTAssertEqual(try fixture.params("experimentalFeature/list")["cursor"] as? String, "page2")
        try fixture.respond("experimentalFeature/list", ["data": [["name": "second", "stage": "stable", "enabled": true, "defaultEnabled": true]]])
        XCTAssertEqual(fixture.controller.experimentalFeatures.map(\.id), ["first", "second"])
        XCTAssertFalse(fixture.controller.settingsLoadingMethods.contains("experimentalFeature/list"))
        fixture.controller.refreshAccountUsage()
        fixture.controller.expireServerRequest(try XCTUnwrap(try fixture.request("account/usage/read")["id"] as? Int))
        XCTAssertNotNil(fixture.controller.settingsErrors["account/usage/read"])
        XCTAssertTrue(fixture.controller.isRunning)
        XCTAssertTrue(fixture.transport.requests("experimentalFeature/enablement/set").isEmpty)
    }

    func testArchivedHistoryUsesOnlyArchivedQueryAndUnarchiveDeduplicates() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        fixture.controller.loadArchivedTaskHistory()
        XCTAssertEqual(try fixture.params("thread/list")["archived"] as? Bool, true)
        try fixture.respond("thread/list", ["data": [fixture.thread(id: "archived")]])
        XCTAssertEqual(fixture.transport.requests("thread/list").count, 1)
        let task = try XCTUnwrap(fixture.controller.workbench.tasks.first)
        fixture.controller.unarchiveTask(task)
        fixture.controller.unarchiveTask(task)
        XCTAssertEqual(fixture.transport.requests("thread/unarchive").count, 1)
        XCTAssertTrue(fixture.controller.archivingTaskIDs.contains(task.id))
        try fixture.fail("thread/unarchive", "Cannot restore now")
        XCTAssertFalse(fixture.controller.archivingTaskIDs.contains(task.id))
        XCTAssertNotNil(fixture.controller.capabilityErrors["thread/unarchive"])
        XCTAssertNil(fixture.controller.capabilityErrors["thread/archive"])
        fixture.controller.unarchiveTask(task)
        try fixture.respond("thread/unarchive", ["thread": fixture.thread(id: "archived")])
        XCTAssertFalse(fixture.controller.workbench.isTaskArchived(task.id))
        XCTAssertNil(fixture.controller.capabilityErrors["thread/unarchive"])
    }

    func testArchivedHistoryReconcilesOnlyAfterAllPagesSucceedAndKeepsLocalArchives() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanUp() }
        let workspaceID = try XCTUnwrap(fixture.controller.workbench.selectedWorkspaceID)
        let remote = fixture.controller.workbench.upsertRemoteTask(workspaceID: workspaceID, threadID: "restored-elsewhere", title: "Remote", state: .completed,
            statusMessage: "", createdAt: Date(), updatedAt: Date())
        fixture.controller.workbench.archiveTask(remote.id)
        let local = fixture.controller.workbench.createTask(workspaceID: workspaceID, prompt: "Local archive")
        fixture.controller.workbench.archiveTask(local.id)
        fixture.controller.loadArchivedTaskHistory()
        try fixture.respond("thread/list", ["data": [], "nextCursor": "more"])
        XCTAssertTrue(fixture.controller.workbench.isTaskArchived(remote.id))
        try fixture.fail("thread/list", "Page failed")
        XCTAssertTrue(fixture.controller.workbench.isTaskArchived(remote.id))
        fixture.controller.loadArchivedTaskHistory()
        try fixture.respond("thread/list", ["data": []])
        XCTAssertFalse(fixture.controller.workbench.isTaskArchived(remote.id))
        XCTAssertTrue(fixture.controller.workbench.isTaskArchived(local.id))
        XCTAssertNil(fixture.controller.capabilityErrors["thread/list"])
    }
}

@MainActor
private struct WorkspaceFixture {
    private let rootDirectory: URL
    let directory: URL
    let attachmentDirectory: URL
    let transport: WorkspaceFakeTransport
    let defaults: WorkspaceMemoryDefaults
    let controller: RuntimeWorkspaceController

    init(restoredThreadID: String? = nil, cachedActivities: [WorkActivity] = [],
         restoredState: SavedTaskState = .completed, initializeTransport: Bool = false,
         lastKnownTurnID: String? = nil, syncEnabled: Bool? = true) throws {
        rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexWorkspaceTests-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        directory = rootDirectory.appendingPathComponent("Workspace", isDirectory: true)
        attachmentDirectory = rootDirectory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = WorkspaceMemoryDefaults()
        if let syncEnabled { defaults.set(syncEnabled, forKey: RuntimeWorkspaceController.codexSyncEnabledKey) }
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: directory, bookmark: Data())
        if let restoredThreadID {
            let task = store.createTask(workspaceID: workspace.id, prompt: "Restored task")
            store.updateTask(id: task.id, threadID: restoredThreadID, state: restoredState, activities: cachedActivities,
                             lastKnownTurnID: lastKnownTurnID)
        }
        defaults.set(Data(), forKey: "codex.workspace.bookmark")
        let capturedTransport = WorkspaceFakeTransport()
        transport = capturedTransport
        controller = RuntimeWorkspaceController(defaults: defaults, outboundMessage: { capturedTransport.messages.append($0) },
                                              attachmentDirectory: attachmentDirectory,
                                              initializeInjectedTransport: initializeTransport)
    }

    func cleanUp() {
        controller.setHistorySyncVisible(false)
        controller.flushPendingTaskSnapshot()
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func enableHistorySync() {
        controller.setHistorySyncVisible(true)
        controller.setHistorySyncAppActive(true)
    }

    func loadUsageTestModels() throws {
        // Establish the injected transport first. In production, initialize's
        // response sends model/list; the fixture has no initialization RPC.
        controller.refreshSkills()
        controller.refreshModels()
        try respond("model/list", ["data": ["model-A", "model-B"].map {
            ["model": $0, "defaultReasoningEffort": "low",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]] as [String: Any]
        }])
    }

    func usageValue() -> [String: Any] {
        ["last": ["inputTokens": 80, "outputTokens": 20, "cachedInputTokens": 50, "totalTokens": 100],
         "total": ["totalTokens": 9_000], "modelContextWindow": 1_000]
    }

    func thread(id: String = "thread-1", cwd: String? = nil) -> [String: Any] {
        ["id": id, "cwd": cwd ?? directory.path, "name": id, "status": ["type": "idle"],
         "createdAt": 1_700_000_000, "updatedAt": 1_700_000_001, "turns": []]
    }

    func completedThread(runtimeStatus: String = "idle") -> [String: Any] {
        var value = thread()
        value["status"] = ["type": runtimeStatus]
        value["turns"] = [["id": "turn-1", "status": "completed", "items": []]]
        return value
    }

    func request(_ method: String) throws -> [String: Any] {
        try XCTUnwrap(transport.requests(method).last, "Expected outbound \(method)")
    }

    func params(_ method: String) throws -> [String: Any] {
        try XCTUnwrap(try request(method)["params"] as? [String: Any])
    }

    func respond(_ method: String, _ result: [String: Any]) throws {
        controller.receiveServerMessage(["id": try XCTUnwrap(try request(method)["id"]), "result": result])
    }

    func fail(_ method: String, _ message: String) throws {
        controller.receiveServerMessage(["id": try XCTUnwrap(try request(method)["id"]), "error": ["code": -32601, "message": message]])
    }

    func notify(_ method: String, _ values: [String: Any]) {
        var params = values
        params["threadId"] = "thread-1"
        controller.receiveServerMessage(["method": method, "params": params])
    }

    func startTurn() throws {
        XCTAssertTrue(controller.submit(prompt: "Begin", images: []))
        try respond("thread/start", ["thread": thread()])
        try respond("turn/start", ["turn": ["id": "turn-1"]])
    }
}

@MainActor
private final class WorkspaceFakeTransport {
    var messages: [[String: Any]] = []
    func requests(_ method: String) -> [[String: Any]] { messages.filter { $0["method"] as? String == method } }
}

private final class WorkspaceMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func data(forKey key: String) -> Data? { lock.withLock { values[key] as? Data } }
    override func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    override func stringArray(forKey key: String) -> [String]? { lock.withLock { values[key] as? [String] } }
    override func bool(forKey key: String) -> Bool { lock.withLock { values[key] as? Bool ?? false } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
}
