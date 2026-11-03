import Foundation
import XCTest
@testable import Marr

@MainActor
final class CodexWorkbenchTests: XCTestCase {
    func testWorkspacePinsRemainEditableWhileFollowingCodexAndPersistOnReload() throws {
        let suite = "Marr.WorkspacePins.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchStore(defaults: defaults)
        store.importProjects([
            ["id": "a", "name": "Pinned", "roots": [["path": "/tmp/pinned"]]],
            ["id": "b", "name": "Other", "roots": [["path": "/tmp/other"]]]
        ])
        let a = try XCTUnwrap(store.workspaces.first { $0.projectID == "a" })
        let b = try XCTUnwrap(store.workspaces.first { $0.projectID == "b" })
        let snapshot = CodexDesktopSidebarSnapshot(projects: [], projectOrder: ["a", "b"],
            pinnedProjectIDs: ["a"], taskOrder: [:], chatSort: "manual", projectSort: "manual", grouping: "project")
        store.applyDesktopSidebarPreferences(snapshot)
        XCTAssertEqual(store.sidebarWorkspaces.filter(\.isPinned).map(\.id), [a.id])
        let selection = store.selectedWorkspaceID
        store.toggleWorkspacePinned(a.id)
        store.toggleWorkspacePinned(b.id)
        store.applyDesktopSidebarPreferences(snapshot)
        XCTAssertEqual(store.sidebarWorkspaces.filter(\.isPinned).map(\.id), [b.id])
        XCTAssertEqual(store.selectedWorkspaceID, selection)
        store.flushPersistence()
        let restored = WorkbenchStore(defaults: defaults)
        restored.applyDesktopSidebarPreferences(snapshot)
        XCTAssertEqual(restored.sidebarWorkspaces.filter(\.isPinned).map(\.id), [b.id])
        restored.followDesktopWorkspacePin(a.id)
        restored.followDesktopWorkspacePin(b.id)
        XCTAssertEqual(restored.sidebarWorkspaces.filter(\.isPinned).map(\.id), [a.id])
        XCTAssertTrue(restored.workspaces.allSatisfy { $0.pinOverride == nil })
    }

    func testLargeLegacyArchiveMigratesToAtomicFileAndKeepsRecoveryBackup() throws {
        let suite = "Marr.ArchiveMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let legacy = WorkbenchStore(defaults: defaults)
        let workspace = legacy.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/migration"), bookmark: Data())
        let task = legacy.createTask(workspaceID: workspace.id, prompt: "Saved question")
        legacy.updateTask(id: task.id, threadID: "migrated-thread", latestAgentMessage: "Legacy answer")
        let legacyData = try XCTUnwrap(defaults.data(forKey: "codex.workbench.v1"))
        let url = directory.appendingPathComponent("workbench.json")
        let migrated = WorkbenchStore(defaults: defaults, archiveURL: url)
        XCTAssertEqual(migrated.selectedTask?.latestAgentMessage, "Legacy answer")
        migrated.flushPersistence()
        XCTAssertNil(defaults.data(forKey: "codex.workbench.v1"))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("legacy-backup")), legacyData)
        let largeAnswer = String(repeating: "Long answer. ", count: 400_000)
        migrated.updateTask(id: task.id, latestAgentMessage: largeAnswer, persistAsynchronously: true)
        migrated.flushPersistence()
        XCTAssertFalse(migrated.persistenceDiagnostics.encodingOnMainThread)
        XCTAssertFalse(migrated.persistenceDiagnostics.writesOnMainThread)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 4_194_304)
        XCTAssertNil(defaults.data(forKey: "codex.workbench.v1"), "Large histories must never return to preferences")
        let restored = WorkbenchStore(defaults: defaults, archiveURL: url)
        XCTAssertEqual(restored.selectedTask?.latestAgentMessage, largeAnswer)
        // Corrupt-file recovery uses the retained migration backup.
        try Data("broken".utf8).write(to: url, options: .atomic)
        let recovered = WorkbenchStore(defaults: defaults, archiveURL: url)
        XCTAssertEqual(recovered.selectedTask?.latestAgentMessage, "Legacy answer")
        recovered.flushPersistence()
    }

    func testFailedFileMigrationPreservesLegacyArchive() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let original = WorkbenchStore(defaults: defaults)
        _ = original.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/preserve-legacy"), bookmark: Data())
        let data = try XCTUnwrap(defaults.data(forKey: "codex.workbench.v1"))
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let migrated = WorkbenchStore(defaults: defaults, archiveURL: blocker.appendingPathComponent("workbench.json"))
        migrated.flushPersistence()
        XCTAssertEqual(defaults.data(forKey: "codex.workbench.v1"), data)
        XCTAssertEqual(migrated.workspaces, original.workspaces)
    }

    func testSidebarMenuProjectCatalogIsBuiltOnceUntilMembershipChanges() throws {
        let store = WorkbenchStore(defaults: InMemoryWorkbenchDefaults())
        store.importProjects((0..<60).map { ["id": "p-\($0)", "name": "Project \($0)",
            "roots": [["path": "/tmp/sidebar-project-\($0)"]]] })
        let legacy = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/legacy-chat"))
        let expected = store.sidebarWorkspaces.map(\.id)
        let builds = store.sidebarProjectBuildCount
        for _ in 0..<500 { XCTAssertEqual(store.sidebarWorkspaces.map(\.id), expected) }
        XCTAssertEqual(store.sidebarProjectBuildCount, builds, "Hover/menu updates must not scan the entire task archive")
        XCTAssertFalse(expected.contains(legacy.id))
        _ = store.upsertRemoteTask(workspaceID: legacy.id, threadID: "legacy", title: "Legacy",
            state: .completed, statusMessage: "Saved", createdAt: Date(), updatedAt: Date())
        XCTAssertTrue(store.sidebarWorkspaces.contains { $0.id == legacy.id })
        XCTAssertEqual(store.sidebarProjectBuildCount, builds + 1)
    }

    func testLegacyNullProjectIDsResolveDesktopAssignmentsAndDirectoryFallbacks() throws {
        let store = WorkbenchStore(defaults: InMemoryWorkbenchDefaults())
        store.importProjects([
            ["id": "a", "name": "A", "roots": [["path": "/tmp/project"]]],
            ["id": "b", "name": "B", "roots": [["path": "/tmp/project/nested"]]]])
        let a = try XCTUnwrap(store.workspaces.first { $0.projectID == "a" })
        let b = try XCTUnwrap(store.workspaces.first { $0.projectID == "b" })
        func add(_ id: String, _ path: String) -> SavedTask {
            let root = store.ensureWorkspace(url: URL(fileURLWithPath: path))
            let task = store.upsertRemoteTask(workspaceID: root.id, threadID: id, title: id,
                state: .completed, statusMessage: "Done", createdAt: Date(), updatedAt: Date())
            store.importThreadSidebarMetadata(["id": id, "projectId": NSNull()])
            return task
        }
        let direct = add("direct", "/tmp/project")
        let nested = add("nested", "/tmp/project/nested/src")
        let worktree = add("worktree", "/tmp/worktrees/topic")
        let loose = add("loose", "/tmp/project")
        let boundary = add("boundary", "/tmp/project-other")
        let source: [String: Any] = ["local-projects": ["legacy-a": ["id": "legacy-a", "name": "A", "rootPaths": ["/tmp/project"]]],
            "pinned-project-ids": [String](),
            "app-server-project-id-by-legacy-project-id-by-host": ["local:/tmp/codex": ["legacy-a": "a"]],
            "thread-project-assignments": ["worktree": ["projectKind": "local", "projectId": "legacy-a"],
                "foreign": ["projectKind": "local", "projectId": "legacy-a"]],
            "thread-project-membership-host-ids": ["foreign": "remote"],
            "projectless-thread-ids": ["loose"]]
        let snapshot = try CodexDesktopSidebarSnapshot.parse(JSONSerialization.data(withJSONObject: source), codexHome: "/tmp/codex")
        XCTAssertEqual(snapshot.threadProjects, ["worktree": "a"])
        XCTAssertEqual(snapshot.version, 2)
        store.applyDesktopSidebarPreferences(snapshot)
        XCTAssertEqual(Set(store.orderedTasks(in: a.id).map(\.id)), [direct.id, worktree.id])
        XCTAssertEqual(store.orderedTasks(in: b.id).map(\.id), [nested.id])
        XCTAssertNil(store.sidebarWorkspaceID(for: loose))
        XCTAssertNil(store.sidebarWorkspaceID(for: boundary))
        // The projection must not discard rows already resolved by the store.
        let projection = try XCTUnwrap(MarrWorkspaceSidebarContent.project(a,
            orderedTasks: store.orderedTasks(in: a.id), searchText: "", isCollapsed: false,
            isExpanded: true, membershipResolved: true))
        XCTAssertEqual(projection.tasks.count, 2)
        store.importThreadSidebarMetadata(["id": "worktree", "projectId": "b"])
        XCTAssertEqual(store.orderedTasks(in: b.id).count, 2)
        store.importThreadSidebarMetadata(["id": "direct", "projectId": NSNull(), "marrExplicitProjectless": true])
        XCTAssertTrue(store.orderedTasks(in: a.id).isEmpty)
        var updated = snapshot
        updated.threadProjects = ["direct": "b"]
        store.applyDesktopSidebarPreferences(updated)
        XCTAssertEqual(store.orderedTasks(in: b.id).count, 3)
    }

    func testDirectDesktopSidebarReadObservesEditsWithoutWritingSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(".codex-global-state.json")
        var state: [String: Any] = ["local-projects": [String: String](), "pinned-project-ids": ["project-a"],
                                    "private-draft": "DO-NOT-EXPORT"]
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: source)
        let snapshot = try CodexDesktopSidebarSnapshot.read(codexHome: directory)
        XCTAssertEqual(snapshot.pinnedProjectIDs, ["project-a"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("DO-NOT-EXPORT"))
        XCTAssertEqual(try Data(contentsOf: source), data)
        state["pinned-project-ids"] = [String]()
        try JSONSerialization.data(withJSONObject: state).write(to: source, options: .atomic)
        XCTAssertTrue(try CodexDesktopSidebarSnapshot.read(codexHome: directory).pinnedProjectIDs.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        try Data("invalid".utf8).write(to: source)
        XCTAssertThrowsError(try CodexDesktopSidebarSnapshot.read(codexHome: directory))
    }

    func testSidebarReaderInvalidatesCachedStateAfterAtomicReplacementAndCorruption() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".codex-global-state.json")
        let reader = CodexDesktopSidebarReader()
        try Data("{\"local-projects\":{},\"pinned-project-ids\":[\"a\"]}".utf8).write(to: file, options: .atomic)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let first = try await reader.read(codexHome: home)
        XCTAssertEqual(first.pinnedProjectIDs, ["a"])
        try Data("{\"local-projects\":{},\"pinned-project-ids\":[\"b\"]}".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let changed = try await reader.read(codexHome: home)
        XCTAssertEqual(changed.pinnedProjectIDs, ["b"])
        try Data("invalid".utf8).write(to: file, options: .atomic)
        do { _ = try await reader.read(codexHome: home); XCTFail("Corruption must invalidate cached success") }
        catch {}
        try Data("{\"local-projects\":{},\"pinned-project-ids\":[\"c\"]}".utf8).write(to: file, options: .atomic)
        let recovered = try await reader.read(codexHome: home)
        XCTAssertEqual(recovered.pinnedProjectIDs, ["c"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [file.lastPathComponent])
    }

    func testCanonicalProjectMembershipDoesNotReplaceExecutionDirectory() throws {
        let store = WorkbenchStore(defaults: InMemoryWorkbenchDefaults())
        store.importProjects([["id": "project-a", "name": "Shared project", "roots": [["path": "/tmp/project-a"]], "position": 0]])
        let project = try XCTUnwrap(store.workspaces.first)
        let worktree = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/worktrees/topic"))
        let task = store.upsertRemoteTask(workspaceID: worktree.id, threadID: "thread-a", title: "Task",
            state: .completed, statusMessage: "Done", createdAt: Date(), updatedAt: Date())
        store.importThreadSidebarMetadata(["id": "thread-a", "projectId": "project-a", "section": NSNull()])
        XCTAssertEqual(store.orderedTasks(in: project.id).map(\.id), [task.id])
        XCTAssertEqual(store.tasks.first?.workspaceID, worktree.id)
        XCTAssertEqual(store.sidebarWorkspaces.map(\.id), [project.id])
        store.importThreadSidebarMetadata(["id": "thread-a", "projectId": NSNull()])
        XCTAssertTrue(store.orderedTasks(in: project.id).isEmpty)
        XCTAssertNil(store.tasks.first?.projectID)
        XCTAssertEqual(store.tasks.first?.hasCanonicalProject, true)
        XCTAssertEqual(store.tasks.first?.workspaceID, worktree.id)
    }

    func testRemotePinAndExplicitUnpinInvalidateCachedRowsButMissingFieldsDoNot() throws {
        let store = WorkbenchStore(defaults: InMemoryWorkbenchDefaults())
        let project = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/pins"))
        let first = store.upsertRemoteTask(workspaceID: project.id, threadID: "a", title: "A",
            state: .completed, statusMessage: "Done", createdAt: .distantPast, updatedAt: .distantPast)
        let second = store.upsertRemoteTask(workspaceID: project.id, threadID: "b", title: "B",
            state: .completed, statusMessage: "Done", createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(store.orderedTasks(in: project.id).first?.id, second.id)
        store.importThreadSidebarMetadata(["id": "a", "section": ["id": WorkbenchStore.pinnedSectionID]])
        XCTAssertEqual(store.orderedTasks(in: project.id).first?.id, first.id)
        store.importThreadSidebarMetadata(["id": "a"])
        XCTAssertTrue(store.isTaskPinned(first.id))
        store.importThreadSidebarMetadata(["id": "b", "section": ["id": WorkbenchStore.pinnedSectionID]])
        store.setSharedPinnedOrder(["a", "b"])
        XCTAssertEqual(store.pinnedSidebarTasks.map(\.id), [first.id, second.id])
        store.importThreadSidebarMetadata(["id": "a", "section": NSNull()])
        XCTAssertFalse(store.isTaskPinned(first.id))
        XCTAssertEqual(store.pinnedSidebarTasks.map(\.id), [second.id])
    }

    func testDesktopSidebarSnapshotMapsLegacyIDsAndExportsOnlyPreferences() throws {
        let source: [String: Any] = [
            "local-projects": ["legacy": ["id": "legacy", "name": "Project", "rootPaths": ["/tmp/project"]]],
            "pinned-project-ids": ["legacy"], "project-order": ["legacy"],
            "sidebar-project-thread-orders": ["legacy": ["old", "new"]],
            "app-server-project-id-by-legacy-project-id-by-host": ["local:/tmp/codex": ["legacy": "canonical"], "remote:other": ["legacy": "wrong-host"]],
            "electron-persisted-atom-state": ["flat-project-sidebar-preferences-v1": ["chatSortMode": "manual", "projectSortMode": "manual", "mode": "project", "manualSortVersion": 1],
                "composer-prompt-drafts-v1": ["secret": "PRIVATE-DRAFT"]], "unrelated": "PRIVATE-VALUE"]
        let snapshot = try CodexDesktopSidebarSnapshot.parse(JSONSerialization.data(withJSONObject: source), codexHome: "/tmp/codex")
        XCTAssertEqual(snapshot.projects.first?.id, "canonical")
        XCTAssertEqual(snapshot.pinnedProjectIDs, ["canonical"])
        XCTAssertEqual(snapshot.taskOrder["canonical"], ["old", "new"])
        let exported = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(exported.contains("PRIVATE"))
        let store = WorkbenchStore(defaults: InMemoryWorkbenchDefaults())
        store.importProjects([["id": "canonical", "name": "Project", "roots": [["path": "/tmp/project"]]]])
        let project = try XCTUnwrap(store.workspaces.first)
        for id in ["old", "new"] {
            _ = store.upsertRemoteTask(workspaceID: project.id, threadID: id, title: id,
                state: .completed, statusMessage: "Done", createdAt: Date(), updatedAt: Date())
        }
        store.applyDesktopSidebarPreferences(snapshot)
        XCTAssertTrue(try XCTUnwrap(store.workspaces.first).isPinned)
        XCTAssertEqual(store.orderedTasks(in: project.id).compactMap(\.threadID), ["old", "new"])
        let cleared = CodexDesktopSidebarSnapshot(projects: snapshot.projects, projectOrder: [], pinnedProjectIDs: [],
            taskOrder: [:], chatSort: "updated_at", projectSort: "updated_at", grouping: "list")
        store.applyDesktopSidebarPreferences(cleared)
        XCTAssertFalse(try XCTUnwrap(store.workspaces.first).isPinned)
        XCTAssertEqual(store.orderedTasks(in: project.id).first?.threadID, "new")
        XCTAssertThrowsError(try CodexDesktopSidebarSnapshot.parse(Data("{}".utf8), codexHome: "/tmp/codex"))
    }

    func testCachedSidebarOrderTracksRenamePinMoveArchiveAndNewTasks() throws {
        let store = WorkbenchStore(defaults: InMemoryWorkbenchDefaults())
        let project = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/sidebar-cache"), bookmark: Data())
        let first = store.createTask(workspaceID: project.id, prompt: "First")
        let second = store.createTask(workspaceID: project.id, prompt: "Second")
        store.updateTask(id: first.id, state: .completed)
        store.updateTask(id: second.id, state: .completed)
        _ = store.orderedTasks(in: project.id)
        XCTAssertTrue(store.renameTask(first.id, name: "Renamed"))
        XCTAssertEqual(store.orderedTasks(in: project.id).first(where: { $0.id == first.id })?.title, "Renamed")
        store.toggleTaskPinned(first.id)
        XCTAssertEqual(store.orderedTasks(in: project.id).first?.id, first.id)
        store.toggleTaskPinned(first.id)
        XCTAssertTrue(store.moveTask(second.id, relativeTo: first.id, placement: .before))
        XCTAssertEqual(store.orderedTasks(in: project.id).first?.id, second.id)
        store.archiveTask(second.id)
        XCTAssertEqual(store.orderedTasks(in: project.id).map(\.id), [first.id])
        store.unarchiveTask(second.id)
        XCTAssertEqual(store.orderedTasks(in: project.id).count, 2)
        let third = store.createTask(workspaceID: project.id, prompt: "Third")
        XCTAssertTrue(store.orderedTasks(in: project.id).contains { $0.id == third.id })
        store.removeWorkspace(project.id)
        XCTAssertTrue(store.orderedTasks(in: project.id).isEmpty)
    }

    func testHistorySelectionDoesNotWaitOnMainThreadPreferenceNotifications() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/history-notifications"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Saved conversation")
        defaults.requiresMainThreadNotification = true

        store.selectWorkspace(workspace.id)
        store.selectTask(task.id)
        store.updateTask(id: task.id, latestAgentMessage: "Restored answer", persistAsynchronously: true)
        store.flushPersistence()

        XCTAssertEqual(defaults.notificationTimeouts, 0,
                       "History selection must not wait for a writer that needs the UI thread to deliver preference notifications")
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedTaskID, task.id)
        XCTAssertEqual(restored.selectedTask?.latestAgentMessage, "Restored answer")
    }

    func testAsynchronousSnapshotCommitsOnMainWithoutExplicitFlush() async {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/async-notifications"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Saved conversation")
        let committed = expectation(description: "Asynchronous archive commit")
        defaults.onArchiveCommit = {
            XCTAssertTrue(Thread.isMainThread)
            committed.fulfill()
        }
        store.updateTask(id: task.id, latestAgentMessage: "Background answer", persistAsynchronously: true)
        await fulfillment(of: [committed], timeout: 2)
        defaults.onArchiveCommit = nil
        XCTAssertEqual(WorkbenchStore(defaults: defaults).selectedTask?.latestAgentMessage, "Background answer")
        XCTAssertFalse(store.persistenceDiagnostics.encodingOnMainThread)
    }

    func testBackgroundSnapshotsPreserveV1ArchiveAndTerminalWriteWinsOverQueuedPartials() async throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/persistence-order"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Persist this task")
        for index in 0..<100 {
            store.updateTask(id: task.id, latestAgentMessage: "Partial \(index)", persistAsynchronously: true)
        }
        store.updateTask(id: task.id, state: .completed, latestAgentMessage: "Terminal answer")
        store.flushPersistence()
        // Previously enqueued main-queue commit callbacks must not restore an
        // older partial after a synchronous terminal snapshot has been saved.
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(store.persistenceDiagnostics.encodingOnMainThread, "Archive encoding must stay outside the UI thread")
        XCTAssertTrue(store.persistenceDiagnostics.writesOnMainThread, "Preference notifications must be delivered on the UI thread")
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedTask?.id, task.id)
        XCTAssertEqual(restored.selectedTask?.state, .completed)
        XCTAssertEqual(restored.selectedTask?.latestAgentMessage, "Terminal answer")
        XCTAssertNotNil(defaults.data(forKey: "codex.workbench.v1"), "The existing archive format remains readable without destructive migration")
    }

    func testExplicitFlushWaitsForLatestAsynchronousSnapshotWithoutEncodingOnMainThread() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/persistence-flush"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Pending stream")
        for index in 0..<100 {
            store.updateTask(id: task.id, latestAgentMessage: "Partial \(index)", persistAsynchronously: true)
        }

        store.flushPersistence()

        XCTAssertEqual(WorkbenchStore(defaults: defaults).selectedTask?.latestAgentMessage, "Partial 99")
        XCTAssertFalse(store.persistenceDiagnostics.encodingOnMainThread)
        XCTAssertTrue(store.persistenceDiagnostics.writesOnMainThread)
    }

    func testManualTaskOrderSurvivesRepliesRemoteRefreshAndRestartWithoutChangingSelection() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
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
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.orderedTasks(in: workspace.id).map(\.id), expected)
        XCTAssertEqual(restored.selectedTaskID, tasks[1].id)
        let fresh = restored.createTask(workspaceID: workspace.id, prompt: "A new local chat")
        XCTAssertEqual(restored.orderedTasks(in: workspace.id).map(\.id), [fresh.id] + expected)
        XCTAssertEqual(WorkbenchStore(defaults: defaults).orderedTasks(in: workspace.id).map(\.id),
                       [fresh.id] + expected)
    }

    func testTaskReorderingCannotCrossProjectPinArchiveOrRunningBoundaries() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
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
        let store = WorkbenchStore(defaults: defaults)
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
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.taskOrderIDs, [duplicate.id, third.id, original.id])
        _ = restored.upsertRemoteTask(workspaceID: workspace.id, threadID: "same-thread",
            title: "Merged", state: .completed, statusMessage: "Done",
            createdAt: original.createdAt, updatedAt: Date())
        XCTAssertEqual(restored.taskOrderIDs, [original.id, third.id])
        XCTAssertEqual(WorkbenchStore(defaults: defaults).taskOrderIDs, [original.id, third.id])
        restored.removeWorkspace(workspace.id)
        XCTAssertTrue(WorkbenchStore(defaults: defaults).taskOrderIDs.isEmpty)
    }

    func testTaskPinsPersistSeparatelyWithoutChangingSelectionOrTaskOrdering() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/pin-project"), bookmark: Data())
        let first = store.createTask(workspaceID: workspace.id, prompt: "First")
        let second = store.createTask(workspaceID: workspace.id, prompt: "Second")
        let originalOrder = store.tasks.map(\.id)
        store.toggleTaskPinned(first.id)
        store.toggleTaskPinned(UUID())
        XCTAssertEqual(store.tasks.map(\.id), originalOrder)
        XCTAssertEqual(store.selectedTaskID, second.id)
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.pinnedTaskIDs, [first.id])
        restored.archiveTask(first.id)
        restored.unarchiveTask(first.id)
        XCTAssertTrue(WorkbenchStore(defaults: defaults).isTaskPinned(first.id))
        restored.toggleTaskPinned(first.id)
        XCTAssertFalse(WorkbenchStore(defaults: defaults).isTaskPinned(first.id))
    }

    func testTaskPinMigrationMergesDuplicatesAndDeletesOrphanedPins() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/pins"), bookmark: Data())
        var original = store.createTask(workspaceID: workspace.id, prompt: "Original")
        var duplicate = store.createTask(workspaceID: workspace.id, prompt: "Duplicate")
        original.threadID = "same-thread"
        duplicate.threadID = "same-thread"
        let orphan = UUID()
        defaults.set([duplicate.id.uuidString, orphan.uuidString, "invalid"], forKey: "codex.workbench.pinned-task-ids.v1")
        try writeArchive(defaults, workspaces: store.workspaces, tasks: [original, duplicate], workspaceID: workspace.id, taskID: original.id)
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.pinnedTaskIDs, [duplicate.id])
        let merged = restored.upsertRemoteTask(workspaceID: workspace.id, threadID: "same-thread", title: "Updated", state: .completed,
            statusMessage: "", createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(restored.pinnedTaskIDs, [original.id])
        XCTAssertEqual(WorkbenchStore(defaults: defaults).pinnedTaskIDs, [original.id])
        restored.removeWorkspace(workspace.id)
        XCTAssertTrue(WorkbenchStore(defaults: defaults).pinnedTaskIDs.isEmpty)
    }

    func testLocalTaskRenamePersistsWithoutChangingIdentityOrAcceptingEmptyTitle() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/rename"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Original")
        XCTAssertFalse(store.renameTask(task.id, name: " \n "))
        XCTAssertTrue(store.renameTask(task.id, name: "  Renamed local chat  "))
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedTask?.id, task.id)
        XCTAssertEqual(restored.selectedTask?.title, "Renamed local chat")
        XCTAssertNil(restored.selectedTask?.threadID)
    }

    func testChoosingAnotherWorkspaceDoesNotResumePreviousProjectAfterRestart() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let task = store.createTask(workspaceID: first.id, prompt: "Task in A")
        store.updateTask(id: task.id, threadID: "thread-a", state: .completed)

        let second = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-b"), bookmark: Data())
        let restored = WorkbenchStore(defaults: defaults)

        XCTAssertEqual(restored.selectedWorkspaceID, second.id)
        XCTAssertNil(restored.selectedTask)
        XCTAssertEqual(restored.tasks.first?.threadID, "thread-a")
    }

    func testSelectingExistingWorkspaceClearsOnlyAnIncompatibleTask() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let second = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/project-b"))
        let task = store.createTask(workspaceID: first.id, prompt: "Task in A")

        store.selectWorkspace(first.id)
        XCTAssertEqual(store.selectedTaskID, task.id)
        store.selectWorkspace(second.id)

        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedWorkspaceID, second.id)
        XCTAssertNil(restored.selectedTaskID)
    }

    func testStartingAnEmptyTaskPersistsNoPreviousTaskSelection() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Previous task")

        store.clearSelectedTask()

        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedWorkspaceID, workspace.id)
        XCTAssertNil(restored.selectedTaskID)
        XCTAssertEqual(restored.tasks.map(\.id), [task.id])
    }

    func testSelectingTaskRestoresItsWorkspaceTogetherWithTask() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let task = store.createTask(workspaceID: first.id, prompt: "Task in A")
        _ = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-b"), bookmark: Data())

        store.selectTask(task.id)

        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(restored.selectedWorkspaceID, first.id)
        XCTAssertEqual(restored.selectedTaskID, task.id)
    }

    func testCatalogAndDiscoveredWorkingDirectoriesPreserveTaskAndAccessGrant() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data([1, 2]))
        let task = store.createTask(workspaceID: workspace.id, prompt: "Keep this selection")
        store.importProjects([
            ["name": "Project title", "roots": [["path": "/tmp/project"]]],
            ["name": "Other project", "roots": [["path": "/tmp/other"]]]
        ])
        let normalized = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/project/../project"))
        let worktree = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/worktrees/topic"))

        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertEqual(normalized.id, workspace.id)
        XCTAssertEqual(restored.workspaces.count, 3)
        XCTAssertEqual(restored.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(restored.selectedTaskID, task.id)
        XCTAssertEqual(restored.selectedWorkspace?.bookmark, Data([1, 2]))
        XCTAssertEqual(restored.selectedWorkspace?.name, "Project title")
        XCTAssertTrue(worktree.bookmark.isEmpty)
    }

    func testRestoreRejectsMismatchedOrMissingSelectionsFromOldArchives() throws {
        let seed = WorkbenchStore(defaults: InMemoryWorkbenchDefaults())
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

            let restored = WorkbenchStore(defaults: defaults)
            XCTAssertEqual(restored.selectedWorkspaceID, expectedWorkspaceID)
            XCTAssertNil(restored.selectedTaskID)
            XCTAssertNil(WorkbenchStore(defaults: defaults).selectedTaskID)
        }
    }

    func testRestoreRejectsArchivedSelectionBeforeExposingTask() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Archived task")
        defaults.set([task.id.uuidString], forKey: "codex.workbench.archived-task-ids.v1")

        let restored = WorkbenchStore(defaults: defaults)

        XCTAssertNil(restored.selectedTaskID)
        XCTAssertEqual(restored.selectedWorkspaceID, workspace.id)
        XCTAssertTrue(restored.isTaskArchived(task.id))
        restored.selectTask(task.id)
        XCTAssertNil(restored.selectedTaskID)
    }

    func testArchiveAndUnarchivePersistWithoutRemovingHistoryOrSelectingTask() {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Keep my history")
        store.archiveTask(task.id)
        let archived = WorkbenchStore(defaults: defaults)
        XCTAssertTrue(archived.isTaskArchived(task.id))
        XCTAssertNil(archived.selectedTaskID)
        XCTAssertEqual(archived.tasks.map(\.id), [task.id])

        archived.unarchiveTask(task.id)
        let restored = WorkbenchStore(defaults: defaults)
        XCTAssertFalse(restored.isTaskArchived(task.id))
        XCTAssertNil(restored.selectedTaskID)
        restored.selectTask(task.id)
        XCTAssertEqual(restored.selectedTaskID, task.id)
    }

    func testRemoteThreadMoveDeduplicatesLegacyWorkspaceCopies() throws {
        let defaults = InMemoryWorkbenchDefaults()
        let store = WorkbenchStore(defaults: defaults)
        let first = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project-a"), bookmark: Data())
        let second = store.ensureWorkspace(url: URL(fileURLWithPath: "/tmp/worktrees/topic"))
        var original = store.createTask(workspaceID: first.id, prompt: "Original thread")
        original.threadID = "shared-thread"
        original.latestAgentMessage = "Keep the original response"
        var duplicate = store.createTask(workspaceID: second.id, prompt: "Duplicate thread")
        duplicate.threadID = "shared-thread"
        try writeArchive(defaults, workspaces: store.workspaces, tasks: [original, duplicate],
                         workspaceID: first.id, taskID: original.id)
        let restored = WorkbenchStore(defaults: defaults)

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
        let store = WorkbenchStore(defaults: defaults)
        let workspace = store.upsertWorkspace(url: URL(fileURLWithPath: "/tmp/project"), bookmark: Data())
        let task = store.createTask(workspaceID: workspace.id, prompt: "Long conversation")
        let longText = String(repeating: "message", count: 2_000)
        var activities = (0..<100).map { index in
            WorkActivity(kind: index.isMultiple(of: 2) ? .user : .message,
                          title: "Message \(index)", detail: index == 0 ? longText : "Text \(index)",
                          turnID: "turn-\(index / 2)")
        }
        activities.append(WorkActivity(kind: .command, title: "Tool", detail: String(repeating: "x", count: 20_000),
                                        serverItemID: "item-1", rawJSON: #"{"type":"mcpToolCall","status":"completed"}"#))

        store.updateTask(id: task.id, activities: activities)

        let restored = WorkbenchStore(defaults: defaults)
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
        _ defaults: UserDefaults, workspaces: [SavedWorkspace], tasks: [SavedTask],
        workspaceID: UUID?, taskID: UUID?
    ) throws {
        let archive = TestWorkbenchArchive(workspaces: workspaces, tasks: tasks,
                                           selectedWorkspaceID: workspaceID, selectedTaskID: taskID)
        defaults.set(try JSONEncoder().encode(archive), forKey: "codex.workbench.v1")
    }
}

private struct TestWorkbenchArchive: Encodable {
    var workspaces: [SavedWorkspace]
    var tasks: [SavedTask]
    var selectedWorkspaceID: UUID?
    var selectedTaskID: UUID?
}

private final class InMemoryWorkbenchDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    var requiresMainThreadNotification = false
    private(set) var notificationTimeouts = 0
    var onArchiveCommit: (() -> Void)?

    override func data(forKey key: String) -> Data? { lock.withLock { values[key] as? Data } }
    override func stringArray(forKey key: String) -> [String]? { lock.withLock { values[key] as? [String] } }
    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
        if requiresMainThreadNotification, key == "codex.workbench.v1", !Thread.isMainThread {
            // Model SwiftUI's synchronous preference observer needing the UI
            // thread. Bound the wait so the regression fails instead of hanging
            // the entire runner like the real lock inversion did.
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { delivered.signal() }
            if delivered.wait(timeout: .now() + 0.2) == .timedOut {
                lock.withLock { notificationTimeouts += 1 }
            }
        }
        if key == "codex.workbench.v1" { onArchiveCommit?() }
    }
}
