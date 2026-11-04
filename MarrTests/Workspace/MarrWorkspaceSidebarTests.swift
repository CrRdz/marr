import Foundation
import XCTest
@testable import Marr

/// Tests the sidebar projection without creating controllers, showing folder
/// pickers, reading an account or starting a Codex transport.
final class MarrWorkspaceSidebarTests: XCTestCase {
    func testDefaultPreviewRetainsWorkbenchOrderAndShowsFiveThenAll() throws {
        let project = workspace(name: "Marr", path: "/projects/Marr")
        // Deliberately not chronological: pinned/manual order belongs to the
        // workbench and must survive the sidebar's projection unchanged.
        let tasks = (0..<8).map { task(in: project, title: "Chat \($0)", updatedAt: Date(timeIntervalSince1970: Double($0))) }
        let preview = try XCTUnwrap(MarrWorkspaceSidebarContent.project(project, orderedTasks: tasks,
            searchText: " \n", isCollapsed: false, isExpanded: false))
        XCTAssertEqual(preview.visibleTasks.map(\.id), Array(tasks.prefix(5)).map(\.id))
        XCTAssertEqual(preview.remainingCount, 3)
        let expanded = try XCTUnwrap(MarrWorkspaceSidebarContent.project(project, orderedTasks: tasks,
            searchText: "", isCollapsed: false, isExpanded: true))
        XCTAssertEqual(expanded.visibleTasks.map(\.id), tasks.map(\.id))
        XCTAssertEqual(expanded.remainingCount, 0)
    }

    func testProjectNameAndFullPathSearchRevealAllChildren() throws {
        let project = workspace(name: "Research", path: "/projects/University/Research")
        let tasks = (0..<7).map { task(in: project, title: "Conversation \($0)") }
        for query in ["  RESEARCH \n", "university/research"] {
            let result = try XCTUnwrap(MarrWorkspaceSidebarContent.project(project, orderedTasks: tasks,
                searchText: query, isCollapsed: true, isExpanded: false))
            XCTAssertFalse(result.isCollapsed)
            XCTAssertTrue(result.isSearching)
            XCTAssertEqual(result.visibleTasks.map(\.id), tasks.map(\.id))
        }
    }

    func testChatSearchFiltersWithinItsRealProjectAndExcludesForeignTasks() throws {
        let project = workspace(name: "Marr", path: "/projects/Marr")
        let other = workspace(name: "Other", path: "/projects/Other")
        let first = task(in: project, title: "Review screenshot quality")
        let unrelated = task(in: project, title: "Translate notes")
        let second = task(in: project, title: "SCREENSHOT crop options")
        let foreign = task(in: other, title: "Screenshot elsewhere")
        let result = try XCTUnwrap(MarrWorkspaceSidebarContent.project(project,
            orderedTasks: [first, unrelated, foreign, second], searchText: "screenshot",
            isCollapsed: false, isExpanded: false))
        XCTAssertEqual(result.tasks.map(\.id), [first.id, second.id])
        XCTAssertNil(MarrWorkspaceSidebarContent.project(project, orderedTasks: [unrelated],
            searchText: "unmatched", isCollapsed: false, isExpanded: false))
    }

    func testClearingSearchRestoresCollapseAndDoesNotCreateWorkspacesForUnmatchedChats() throws {
        let project = workspace(name: "Empty", path: "/projects/Empty")
        let match = try XCTUnwrap(MarrWorkspaceSidebarContent.project(project, orderedTasks: [],
            searchText: "empty", isCollapsed: true, isExpanded: false))
        XCTAssertFalse(match.isCollapsed)
        XCTAssertTrue(match.tasks.isEmpty)
        let restored = try XCTUnwrap(MarrWorkspaceSidebarContent.project(project, orderedTasks: [],
            searchText: "", isCollapsed: true, isExpanded: false))
        XCTAssertTrue(restored.isCollapsed)
        XCTAssertFalse(restored.isExpanded)
        XCTAssertTrue(restored.visibleTasks.isEmpty)
        XCTAssertNil(MarrWorkspaceSidebarContent.project(project, orderedTasks: [], searchText: "local screenshot",
                                                         isCollapsed: false, isExpanded: true))
    }

    func testOnlyConfirmedSelectedTaskActivityIsPresentedAsLiveRunning() {
        XCTAssertEqual(status(.running), .savedRunning)
        XCTAssertEqual(status(.completed, selected: false, running: true), .completed)
        XCTAssertEqual(status(.running, selected: false, running: true, remote: true), .savedRunning)
        XCTAssertEqual(status(.running, selected: true, running: true), .running)
        XCTAssertEqual(status(.running, selected: true, remote: true), .running)
        XCTAssertEqual(status(.running, selected: true, remote: true, uncertain: true), .unknown)
        XCTAssertEqual(status(.running, selected: true, remote: true, uncertain: true, reconciling: true), .checking)
        XCTAssertEqual(status(.completed, selected: true, reading: true), .loading)
        XCTAssertEqual(status(.running, selected: true, running: true, needsInput: true), .needsInput)
        XCTAssertEqual(status(.failed), .failed)
        XCTAssertEqual(status(.interrupted), .interrupted)
    }

    func testSwitchingGuardProtectsAllInFlightStates() {
        XCTAssertNil(block())
        XCTAssertNotNil(block(running: true))
        XCTAssertNotNil(block(remote: true))
        XCTAssertNotNil(block(reading: true))
        XCTAssertNotNil(block(uncertain: true))
        XCTAssertNotNil(block(reconciling: true))
        XCTAssertNotNil(block(refreshing: true))
        XCTAssertEqual(block(remote: true, uncertain: true), "Wait until the current task's status is confirmed.")
    }

    func testSameNamedProjectsKeepDistinctPathsAndHomeAbbreviationHasPathBoundary() {
        let first = workspace(name: "Notes", path: "/Users/test/work/Notes")
        let second = workspace(name: "Notes", path: "/Users/test/study/Notes")
        XCTAssertEqual(first.name, second.name)
        XCTAssertTrue(MarrWorkspaceSidebarContent.needsPathDisambiguation(first, among: [first, second]))
        XCTAssertFalse(MarrWorkspaceSidebarContent.needsPathDisambiguation(first, among: [first]))
        let unique = workspace(name: "Marr", path: "/Users/test/work/Marr")
        XCTAssertFalse(MarrWorkspaceSidebarContent.needsPathDisambiguation(unique, among: [first, second, unique]))
        XCTAssertEqual(MarrWorkspaceSidebarContent.displayPath(first.path, homeDirectory: "/Users/test"), "~/work/Notes")
        XCTAssertEqual(MarrWorkspaceSidebarContent.displayPath(second.path, homeDirectory: "/Users/test"), "~/study/Notes")
        XCTAssertEqual(MarrWorkspaceSidebarContent.displayPath("/Users/tester/Notes", homeDirectory: "/Users/test"), "/Users/tester/Notes")
        XCTAssertEqual(MarrWorkspaceSidebarContent.displayPath("/Users/test", homeDirectory: "/Users/test"), "~")
        XCTAssertEqual(MarrWorkspaceSidebarContent.displayPath("/Notes", homeDirectory: "/"), "/Notes")
    }

    func testRenameWaitsForTheExactSelectedConversationAndSuccessfulRead() {
        let target = UUID()
        XCTAssertTrue(MarrWorkspaceSidebarContent.canPresentRename(targetID: target, selectedID: target,
            canSubmit: true, canRename: true, hasReadError: false))
        XCTAssertFalse(MarrWorkspaceSidebarContent.canPresentRename(targetID: target, selectedID: UUID(),
            canSubmit: true, canRename: true, hasReadError: false))
        XCTAssertFalse(MarrWorkspaceSidebarContent.canPresentRename(targetID: target, selectedID: target,
            canSubmit: false, canRename: true, hasReadError: false))
        XCTAssertFalse(MarrWorkspaceSidebarContent.canPresentRename(targetID: target, selectedID: target,
            canSubmit: true, canRename: false, hasReadError: false))
        XCTAssertFalse(MarrWorkspaceSidebarContent.canPresentRename(targetID: target, selectedID: target,
            canSubmit: true, canRename: true, hasReadError: true))
        XCTAssertFalse(MarrWorkspaceSidebarContent.canPresentRename(targetID: nil, selectedID: nil,
            canSubmit: true, canRename: true, hasReadError: false))
    }

    func testLongTitleScrollWaitsAndStaysWithinItsOverflow() {
        XCTAssertEqual(MarrTitleMarquee.offset(elapsed: 0.5, overflow: 84), 0)
        XCTAssertEqual(MarrTitleMarquee.offset(elapsed: 2.2, overflow: 84), -42, accuracy: 0.001)
        XCTAssertEqual(MarrTitleMarquee.offset(elapsed: 4, overflow: 84), -84, accuracy: 0.001)
        XCTAssertEqual(MarrTitleMarquee.offset(elapsed: 10, overflow: 0), 0)
        for elapsed in stride(from: 0.0, through: 30.0, by: 0.1) {
            let offset = MarrTitleMarquee.offset(elapsed: elapsed, overflow: 84)
            XCTAssertTrue((-84...0).contains(offset))
        }
    }

    private func workspace(name: String, path: String) -> SavedWorkspace {
        SavedWorkspace(id: UUID(), name: name, path: path, bookmark: Data(), lastUsedAt: Date())
    }

    private func task(in project: SavedWorkspace, title: String, updatedAt: Date = Date()) -> SavedTask {
        SavedTask(id: UUID(), workspaceID: project.id, title: title, threadID: UUID().uuidString,
            state: .completed, statusMessage: "Done", latestAgentMessage: "", latestDiff: "", activities: [],
            createdAt: updatedAt, updatedAt: updatedAt)
    }

    private func status(_ savedState: SavedTaskState, selected: Bool = false, running: Bool = false,
                        remote: Bool = false, reading: Bool = false, uncertain: Bool = false,
                        reconciling: Bool = false, needsInput: Bool = false) -> MarrWorkspaceSidebarContent.TaskStatus {
        MarrWorkspaceSidebarContent.status(savedState: savedState, isSelected: selected, isRunning: running,
            isRemoteTaskActive: remote, isReading: reading, isUncertain: uncertain,
            isReconciling: reconciling, needsInput: needsInput)
    }

    private func block(running: Bool = false, remote: Bool = false, reading: Bool = false,
                       uncertain: Bool = false, reconciling: Bool = false, refreshing: Bool = false) -> String? {
        MarrWorkspaceSidebarContent.switchingBlockReason(isRunning: running, isRemoteTaskActive: remote,
            isReading: reading, isUncertain: uncertain, isReconciling: reconciling, isRefreshing: refreshing)
    }
}
