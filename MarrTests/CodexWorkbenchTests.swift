import Foundation
import XCTest
@testable import Marr

@MainActor
final class CodexWorkbenchTests: XCTestCase {
    func testManualTaskOrderSurvivesRepliesRemoteRefreshAndRestartWithoutChangingSelection() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/manual-order"), bookmark: Data())
        let tasks = (0..<3).map { index in
            store.upsertRemoteTask(workspaceID: workspace.id, threadID: "thread-\(index)",
                title: "Task \(index)", state: .completed, statusMessage: "Done",
                createdAt: Date(timeIntervalSince1970: Double(index)),
                updatedAt: Date(timeIntervalSince1970: Double(index)))
        }
        store.selectTask(tasks[1].id)
        let dates = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.updatedAt) })
        XCTAssertEqual(store.orderedTasks(in: workspace.id).map(\.id), [tasks[2].id, tasks[1].id, tasks[0].id])
        XCTAssertTrue(store.moveTask(tasks[0].id, direction: .up))
        let expected = [tasks[2].id, tasks[0].id, tasks[1].id]
        XCTAssertEqual(store.orderedTasks(in: workspace.id).map(\.id), expected)
        XCTAssertEqual(store.selectedTaskID, tasks[1].id)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.updatedAt) }), dates)

        store.updateTask(id: tasks[1].id, latestAgentMessage: "A later response must not undo manual order")
        XCTAssertTrue(store.renameTask(tasks[0].id, name: "Renamed"))
        _ = store.upsertRemoteTask(workspaceID: workspace.id, threadID: "thread-1",
            title: "Refreshed", state: .completed, statusMessage: "Done",
            createdAt: tasks[1].createdAt, updatedAt: Date().addingTimeInterval(100))
        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.orderedTasks(in: workspace.id).map(\.id), expected)
        XCTAssertEqual(restored.selectedTaskID, tasks[1].id)
        let fresh = restored.createTask(workspaceID: workspace.id, prompt: "A new local chat")
        XCTAssertEqual(restored.orderedTasks(in: workspace.id).map(\.id), [fresh.id] + expected)
        XCTAssertEqual(CodexWorkbenchStore(defaults: defaults).orderedTasks(in: workspace.id).map(\.id),
                       [fresh.id] + expected)
    }

    func testTaskReorderingCannotCrossProjectPinArchiveOrRunningBoundaries() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let project = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/order-boundaries"), bookmark: Data())
        let other = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/other-order-project"))
        let pinned = store.createTask(workspaceID: project.id, prompt: "Pinned")
        let first = store.createTask(workspaceID: project.id, prompt: "First")
        let second = store.createTask(workspaceID: project.id, prompt: "Second")
        let foreign = store.createTask(workspaceID: other.id, prompt: "Other project")
        for task in [pinned, first, second, foreign] { store.updateTask(id: task.id, state: .completed) }
        store.toggleTaskPinned(pinned.id)
        XCTAssertEqual(store.orderedTasks(in: project.id).first?.id, pinned.id)
        XCTAssertFalse(store.canMoveTask(pinned.id, direction: .down))
        XCTAssertFalse(store.moveTask(second.id, relativeTo: pinned.id, placement: .before))
        XCTAssertFalse(store.moveTask(second.id, relativeTo: foreign.id, placement: .after))
        XCTAssertFalse(store.moveTask(second.id, relativeTo: second.id, placement: .before))
        XCTAssertFalse(store.moveTask(UUID(), relativeTo: second.id, placement: .before))
        store.archiveTask(first.id)
        XCTAssertFalse(store.moveTask(second.id, relativeTo: first.id, placement: .before))
        store.unarchiveTask(first.id)
        store.updateTask(id: first.id, state: .running)
        XCTAssertFalse(store.canMoveTask(second.id, direction: .up))
        XCTAssertFalse(store.moveTask(second.id, relativeTo: first.id, placement: .before))
        store.updateTask(id: first.id, state: .completed)
        XCTAssertTrue(store.moveTask(second.id, relativeTo: first.id, placement: .before))
        XCTAssertEqual(store.orderedTasks(in: project.id).map(\.id), [pinned.id, second.id, first.id])
        XCTAssertEqual(store.orderedTasks(in: other.id).map(\.id), [foreign.id])
        XCTAssertTrue(store.isTaskPinned(pinned.id))
    }

    func testTaskOrderMigrationSanitizesMissingIDsAndKeepsPositionWhenRemoteDuplicatesMerge() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/order-migration"), bookmark: Data())
        var original = store.createTask(workspaceID: workspace.id, prompt: "Original")
        var duplicate = store.createTask(workspaceID: workspace.id, prompt: "Legacy copy")
        let third = store.createTask(workspaceID: workspace.id, prompt: "Another task")
        original.threadID = "same-thread"
        duplicate.threadID = "same-thread"
        try writeArchive(defaults, workspaces: store.workspaces, tasks: [original, duplicate, third],
                         workspaceID: workspace.id, taskID: original.id)
        defaults.set([duplicate.id.uuidString, duplicate.id.uuidString, "invalid", UUID().uuidString,
                      third.id.uuidString, original.id.uuidString], forKey: "codex.workbench.task-order.v1")
        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.taskOrderIDs, [duplicate.id, third.id, original.id])
        _ = restored.upsertRemoteTask(workspaceID: workspace.id, threadID: "same-thread",
            title: "Merged", state: .completed, statusMessage: "Done",
            createdAt: original.createdAt, updatedAt: Date())
        XCTAssertEqual(restored.taskOrderIDs, [original.id, third.id])
        XCTAssertEqual(CodexWorkbenchStore(defaults: defaults).taskOrderIDs, [original.id, third.id])
        restored.removeWorkspace(workspace.id)
        XCTAssertTrue(CodexWorkbenchStore(defaults: defaults).taskOrderIDs.isEmpty)
    }

    func testTaskPinsPersistSeparatelyWithoutChangingSelectionOrTaskOrdering() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/pin-project"), bookmark: Data())
        let first = store.createTask(workspaceID: workspace.id, prompt: "First")
        let second = store.createTask(workspaceID: workspace.id, prompt: "Second")
        let originalOrder = store.tasks.map(\.id)
        store.toggleTaskPinned(first.id)
        store.toggleTaskPinned(UUID())
        XCTAssertEqual(store.tasks.map(\.id), originalOrder)
        XCTAssertEqual(store.selectedTaskID, second.id)
        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.pinnedTaskIDs, [first.id])
        restored.archiveTask(first.id)
        restored.unarchiveTask(first.id)
        XCTAssertTrue(CodexWorkbenchStore(defaults: defaults).isTaskPinned(first.id))
        restored.toggleTaskPinned(first.id)
        XCTAssertFalse(CodexWorkbenchStore(defaults: defaults).isTaskPinned(first.id))
    }

    func testTaskPinMigrationMergesDuplicatesAndDeletesOrphanedPins() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/pins"), bookmark: Data())
        var original = store.createTask(workspaceID: workspace.id, prompt: "Original")
        var duplicate = store.createTask(workspaceID: workspace.id, prompt: "Duplicate")
        original.threadID = "same-thread"
        duplicate.threadID = "same-thread"
        let orphan = UUID()
        defaults.set([duplicate.id.uuidString, orphan.uuidString, "invalid"], forKey: "codex.workbench.pinned-task-ids.v1")
        try writeArchive(defaults, workspaces: store.workspaces, tasks: [original, duplicate], workspaceID: workspace.id, taskID: original.id)
        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.pinnedTaskIDs, [duplicate.id])
        let merged = restored.upsertRemoteTask(workspaceID: workspace.id, threadID: "same-thread", title: "Updated", state: .completed,
            statusMessage: "", createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(restored.pinnedTaskIDs, [original.id])
        XCTAssertEqual(CodexWorkbenchStore(defaults: defaults).pinnedTaskIDs, [original.id])
        restored.removeWorkspace(workspace.id)
        XCTAssertTrue(CodexWorkbenchStore(defaults: defaults).pinnedTaskIDs.isEmpty)
    }

    func testLocalTaskRenamePersistsWithoutChangingIdentityOrAcceptingEmptyTitle() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/rename"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Original")
        XCTAssertFalse(store.renameTask(task.id, name: " \n "))
        XCTAssertTrue(store.renameTask(task.id, name: "  Renamed local chat  "))
        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedTask?.id, task.id)
        XCTAssertEqual(restored.selectedTask?.title, "Renamed local chat")
        XCTAssertNil(restored.selectedTask?.threadID)
    }

    func testChoosingAnotherWorkspaceDoesNotResumePreviousProjectAfterRestart() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let task = store.createTask(workspaceID: first.id, prompt: "Task in A")
        store.updateTask(id: task.id, threadID: "thread-a", state: .completed)

        let second = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-b"), bookmark: Data())
        let restored = CodexWorkbenchStore(defaults: defaults)

        XCTAssertEqual(restored.selectedWorkspaceID, second.id)
        XCTAssertNil(restored.selectedTask)
        XCTAssertEqual(restored.tasks.first?.threadID, "thread-a")
    }

    func testSelectingExistingWorkspaceClearsOnlyAnIncompatibleTask() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let second = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/project-b"))
        let task = store.createTask(workspaceID: first.id, prompt: "Task in A")

        store.selectWorkspace(first.id)
        XCTAssertEqual(store.selectedTaskID, task.id)
        store.selectWorkspace(second.id)

        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedWorkspaceID, second.id)
        XCTAssertNil(restored.selectedTaskID)
    }

    func testStartingAnEmptyTaskPersistsNoPreviousTaskSelection() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Previous task")

        store.clearSelectedTask()

        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedWorkspaceID, workspace.id)
        XCTAssertNil(restored.selectedTaskID)
        XCTAssertEqual(restored.tasks.map(\.id), [task.id])
    }

    func testSelectingTaskRestoresItsWorkspaceTogetherWithTask() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let task = store.createTask(workspaceID: first.id, prompt: "Task in A")
        _ = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-b"), bookmark: Data())

        store.selectTask(task.id)

        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedWorkspaceID, first.id)
        XCTAssertEqual(restored.selectedTaskID, task.id)
    }

    func testCatalogAndDiscoveredWorkingDirectoriesPreserveTaskAndAccessGrant() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data([1, 2]))
        let task = store.createTask(workspaceID: workspace.id, prompt: "Keep this selection")
        store.importProjects([
            ["name": "Project title", "roots": [["path": "/tmp/project"]]],
            ["name": "Other project", "roots": [["path": "/tmp/other"]]]
        ])
        let normalized = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/project/../project"))
        let worktree = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/worktrees/topic"))

        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertEqual(normalized.id, workspace.id)
        XCTAssertEqual(restored.workspaces.count, 3)
        XCTAssertEqual(restored.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(restored.selectedTaskID, task.id)
        XCTAssertEqual(restored.selectedWorkspace?.bookmark, Data([1, 2]))
        XCTAssertEqual(restored.selectedWorkspace?.name, "Project title")
        XCTAssertTrue(worktree.bookmark.isEmpty)
    }

    func testRestoreRejectsMismatchedOrMissingSelectionsFromOldArchives() throws {
        let seed = CodexWorkbenchStore(defaults: InMemoryWorkbenchDefaults())
        let first = seed.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let second = seed.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/project-b"))
        let task = seed.createTask(workspaceID: first.id, prompt: "Task in A")
        let selections: [(UUID?, UUID?, UUID?)] = [
            (second.id, task.id, second.id),
            (UUID(), task.id, nil),
            (first.id, UUID(), first.id),
            (nil, task.id, nil)
        ]

        for (workspaceID, taskID, expectedWorkspaceID) in selections {
            let defaults = InMemoryWorkbenchDefaults()
            try writeArchive(defaults, workspaces: seed.workspaces, tasks: seed.tasks,
                             workspaceID: workspaceID, taskID: taskID)

            let restored = CodexWorkbenchStore(defaults: defaults)
            XCTAssertEqual(restored.selectedWorkspaceID, expectedWorkspaceID)
            XCTAssertNil(restored.selectedTaskID)
            XCTAssertNil(CodexWorkbenchStore(defaults: defaults).selectedTaskID)
        }
    }

    func testRestoreRejectsArchivedSelectionBeforeExposingTask() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Archived task")
        defaults.set([task.id.uuidString], forKey: "codex.workbench.archived-task-ids.v1")

        let restored = CodexWorkbenchStore(defaults: defaults)

        XCTAssertNil(restored.selectedTaskID)
        XCTAssertEqual(restored.selectedWorkspaceID, workspace.id)
        XCTAssertTrue(restored.isTaskArchived(task.id))
        restored.selectTask(task.id)
        XCTAssertNil(restored.selectedTaskID)
    }

    func testArchiveAndUnarchivePersistWithoutRemovingHistoryOrSelectingTask() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Keep my history")
        store.archiveTask(task.id)
        let archived = CodexWorkbenchStore(defaults: defaults)
        XCTAssertTrue(archived.isTaskArchived(task.id))
        XCTAssertNil(archived.selectedTaskID)
        XCTAssertEqual(archived.tasks.map(\.id), [task.id])

        archived.unarchiveTask(task.id)
        let restored = CodexWorkbenchStore(defaults: defaults)
        XCTAssertFalse(restored.isTaskArchived(task.id))
        XCTAssertNil(restored.selectedTaskID)
        restored.selectTask(task.id)
        XCTAssertEqual(restored.selectedTaskID, task.id)
    }

    func testRemoteThreadMoveDeduplicatesLegacyWorkspaceCopies() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let second = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/worktrees/topic"))
        var original = store.createTask(workspaceID: first.id, prompt: "Original thread")
        original.threadID = "shared-thread"
        original.latestAgentMessage = "Keep the original response"
        var duplicate = store.createTask(workspaceID: second.id, prompt: "Duplicate thread")
        duplicate.threadID = "shared-thread"
        try writeArchive(defaults, workspaces: store.workspaces, tasks: [original, duplicate],
                         workspaceID: first.id, taskID: original.id)
        let restored = CodexWorkbenchStore(defaults: defaults)

        let imported = restored.upsertRemoteTask(
            workspaceID: second.id, threadID: "shared-thread", title: "Moved thread", state: .completed,
            statusMessage: "Synced", createdAt: original.createdAt, updatedAt: Date()
        )

        XCTAssertEqual(restored.tasks.count, 1)
        XCTAssertEqual(imported.id, original.id)
        XCTAssertEqual(imported.workspaceID, second.id)
        XCTAssertEqual(imported.latestAgentMessage, "Keep the original response")
        XCTAssertNil(restored.selectedTaskID)
        let same = restored.upsertRemoteTask(
            workspaceID: first.id, threadID: "shared-thread", title: "Moved again", state: .completed,
            statusMessage: "Synced", createdAt: original.createdAt, updatedAt: Date()
        )
        XCTAssertEqual(same.id, original.id)
        XCTAssertEqual(restored.tasks.count, 1)
    }

    func testCachePreservesEarlierTurnsLongMessagesAndProtocolMetadata() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = CodexWorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Long conversation")
        let longText = String(repeating: "message", count: 2_000)
        var activities = (0..<100).map { index in
            CodexActivity(kind: index.isMultiple(of: 2) ? .user : .message,
                          title: "Message \(index)", detail: index == 0 ? longText : "Text \(index)",
                          turnID: "turn-\(index / 2)")
        }
        activities.append(CodexActivity(kind: .command, title: "Tool", detail: String(repeating: "x", count: 20_000),
                                        serverItemID: "item-1", rawJSON: #"{"type":"mcpToolCall","status":"completed"}"#))

        store.updateTask(id: task.id, activities: activities)

        let restored = CodexWorkbenchStore(defaults: defaults)
        let cached = restored.selectedTask?.activities ?? []
        XCTAssertEqual(cached.count, 101)
        XCTAssertEqual(cached.first?.detail, longText)
        XCTAssertEqual(cached.first?.turnID, "turn-0")
        XCTAssertEqual(cached.last?.serverItemID, "item-1")
        XCTAssertEqual(cached.last?.rawJSON, activities.last?.rawJSON)
        XCTAssertTrue(cached.last?.detail.contains("Cached output truncated") == true)
        XCTAssertLessThan(cached.last?.detail.count ?? .max, 20_000)
    }

    private func writeArchive(
        _ defaults: UserDefaults, workspaces: [CodexSavedWorkspace], tasks: [CodexSavedTask],
        workspaceID: UUID?, taskID: UUID?
    ) throws {
        let archive = TestWorkbenchArchive(workspaces: workspaces, tasks: tasks,
                                           selectedWorkspaceID: workspaceID, selectedTaskID: taskID)
        defaults.set(try JSONEncoder().encode(archive), forKey: "codex.workbench.v1")
    }
}

private struct TestWorkbenchArchive: Encodable {
    var workspaces: [CodexSavedWorkspace]
    var tasks: [CodexSavedTask]
    var selectedWorkspaceID: UUID?
    var selectedTaskID: UUID?
}

private final class InMemoryWorkbenchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
