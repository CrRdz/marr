import Foundation
import MarrCore
import XCTest
@testable import Marr

/// Pure history projection only; no views, application lifecycle or windows.
final class MarrHistorySidebarTests: XCTestCase {
    func testGlobalSearchFindsContentAndWorkspaceButExcludesArchivedLocalChats() {
        var saved = record(at: Date(), title: "Design review", turns: [turn(question: "Align the sidebar", answer: "Use a shared toolbar")])
        XCTAssertTrue(MarrGlobalSearchContent.matches(saved, query: "  TOOLBAR\n"))
        XCTAssertTrue(MarrGlobalSearchContent.matches(saved, query: "sidebar"))
        XCTAssertTrue(MarrGlobalSearchContent.matches(saved, query: "openlens", workspaceName: "OpenLens"))
        XCTAssertFalse(MarrGlobalSearchContent.matches(saved, query: "unrelated"))
        saved.archivedAt = Date()
        XCTAssertFalse(MarrGlobalSearchContent.matches(saved, query: ""))
        XCTAssertFalse(MarrGlobalSearchContent.matches(saved, query: "Design"))
    }

    func testGlobalSearchFindsSavedWorkRepliesAndWorkspaceNames() {
        let task = SavedTask(id: UUID(), workspaceID: UUID(), title: "Review", threadID: "test",
            state: .completed, statusMessage: "Done", latestAgentMessage: "The glass gradient is ready",
            latestDiff: "", activities: [], createdAt: Date(), updatedAt: Date())
        XCTAssertTrue(MarrGlobalSearchContent.matches(task, query: " GRADIENT "))
        XCTAssertTrue(MarrGlobalSearchContent.matches(task, query: "notes", workspaceName: "StudyNotes"))
        XCTAssertFalse(MarrGlobalSearchContent.matches(task, query: "unrelated"))
    }

    func testDateSectionsRespectLocalDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // The preceding calendar day lasted 23 hours. Elapsed-hour grouping would be wrong.
        let now = try date(2026, 3, 9, hour: 0, minute: 10, calendar: calendar)
        let yesterday = try date(2026, 3, 8, hour: 0, minute: 20, calendar: calendar)
        XCTAssertLessThan(now.timeIntervalSince(yesterday), 24 * 60 * 60)
        XCTAssertEqual(MarrHistorySidebarContent.dateGroup(for: yesterday, now: now, calendar: calendar), .yesterday)
        let lastWeek = try date(2026, 3, 3, calendar: calendar)
        let sevenDaysAgo = try date(2026, 3, 2, calendar: calendar)
        XCTAssertEqual(MarrHistorySidebarContent.dateGroup(for: lastWeek, now: now, calendar: calendar), .previous7Days)
        XCTAssertEqual(MarrHistorySidebarContent.dateGroup(for: sevenDaysAgo, now: now, calendar: calendar), .previous30Days)
    }

    func testDateSectionsCoverMidnightOldRecordsAndFutureClockValues() throws {
        let calendar = utcCalendar
        let now = try date(2026, 10, 23, calendar: calendar)
        let dates: [(Int, MarrHistorySidebarContent.DateGroup)] = [
            (-1, .future), (0, .today), (1, .yesterday), (2, .previous7Days),
            (6, .previous7Days), (7, .previous30Days), (29, .previous30Days), (30, .older)
        ]
        for (days, expected) in dates {
            let timestamp = try XCTUnwrap(calendar.date(byAdding: .day, value: -days, to: now))
            XCTAssertEqual(MarrHistorySidebarContent.dateGroup(for: timestamp, now: now, calendar: calendar), expected)
        }
        let beforeMidnight = now.addingTimeInterval(-1)
        XCTAssertEqual(MarrHistorySidebarContent.dateGroup(for: beforeMidnight, now: now, calendar: calendar), .yesterday)
    }

    func testSearchUsesSavedTitleQuestionAnswerAndErrorWithoutLosingGrouping() throws {
        let now = try date(2026, 10, 23, calendar: utcCalendar)
        let titled = record(at: now, title: "Vector result")
        let question = record(at: now.addingTimeInterval(-86_400), turns: [turn(question: "Explain VECTOR indexes")])
        let answer = record(at: now.addingTimeInterval(-2 * 86_400), turns: [turn(answer: "The vector has two dimensions.")])
        let error = record(at: now, turns: [turn(error: "Vector provider unavailable", status: .failed)])
        let unrelated = record(at: now, title: "Another topic")
        let sections = MarrHistorySidebarContent.sections(for: [unrelated, answer, question, error, titled],
                                                          searchText: "  vEcToR\n", now: now, calendar: utcCalendar)
        XCTAssertEqual(sections.map(\.group), [.today, .yesterday, .previous7Days])
        XCTAssertEqual(Set(sections.flatMap(\.conversations).map(\.id)), Set([titled.id, question.id, answer.id, error.id]))
        XCTAssertTrue(MarrHistorySidebarContent.sections(for: [titled], searchText: "absent", now: now, calendar: utcCalendar).isEmpty)
    }

    func testOrderingIsMostRecentFirstAndStableForEqualDates() throws {
        let now = try date(2026, 10, 23, hour: 12, calendar: utcCalendar)
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = record(id: firstID, at: now)
        let second = record(id: secondID, at: now)
        let older = record(at: now.addingTimeInterval(-60))
        let sections = MarrHistorySidebarContent.sections(for: [older, second, first], searchText: " \n", now: now,
                                                          calendar: utcCalendar)
        XCTAssertEqual(sections.flatMap(\.conversations).map(\.id), [firstID, secondID, older.id])
    }

    func testSummaryShowsLatestFailureInsteadOfAnEarlierAnswer() {
        let saved = record(at: Date(), turns: [
            turn(answer: "Earlier successful answer"),
            turn(question: "Try again", error: " Request\n timed out ", status: .failed)
        ])
        XCTAssertEqual(MarrHistorySidebarContent.summary(for: saved), "Error: Request timed out")
        let pending = record(at: Date(), turns: [turn(answer: "Old answer"), turn(question: "Latest question", status: .loading)])
        XCTAssertEqual(MarrHistorySidebarContent.summary(for: pending), "Latest question")
    }

    func testSnippetsCollapseWhitespaceAndPreserveWholeUnicodeCharacters() {
        XCTAssertEqual(MarrHistorySidebarContent.compactSnippet(" \n A\t B \r\n C "), "A B C")
        XCTAssertEqual(MarrHistorySidebarContent.compactSnippet("👨‍👩‍👧‍👦你好世界", limit: 3), "👨‍👩‍👧‍👦你好…")
        XCTAssertEqual(MarrHistorySidebarContent.compactSnippet("abc   ", limit: 3), "abc")
        XCTAssertEqual(MarrHistorySidebarContent.compactSnippet("any", limit: 0), "")
        XCTAssertEqual(MarrHistorySidebarContent.compactSnippet(" \t\n "), "")
    }

    func testEmptyAndAttachmentOnlyHistoryHasUsefulSummaryWithoutDoubleCounting() {
        var saved = record(at: Date())
        XCTAssertEqual(MarrHistorySidebarContent.summary(for: saved), "Empty conversation")
        let attachmentID = UUID()
        saved.images = [.init(id: attachmentID, mimeType: "image/png", fileName: "Screenshot.png", storedFileName: "image.png")]
        saved.pendingImageIDs = [attachmentID]
        XCTAssertEqual(MarrHistorySidebarContent.summary(for: saved), "1 attachment")
        saved.pendingImageIDs.append(UUID())
        XCTAssertEqual(MarrHistorySidebarContent.summary(for: saved), "2 attachments")
    }

    func testMixedConversationsSortAcrossSourcesAndKeepSourceIdentity() {
        let sharedID = UUID()
        let local = record(id: sharedID, at: Date(timeIntervalSince1970: 20), title: "Local")
        let remote = SavedTask(id: sharedID, workspaceID: UUID(), title: "Codex", threadID: "test",
            state: .completed, statusMessage: "Done", latestAgentMessage: "", latestDiff: "", activities: [],
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))
        let newest = record(at: Date(timeIntervalSince1970: 30), title: "Newest")
        let rows = MarrMixedConversationContent.rows(local: [local, newest], codex: [remote], query: "")
        XCTAssertEqual(rows.map(\.id), ["local-" + newest.id.uuidString, "local-" + sharedID.uuidString, "codex-" + sharedID.uuidString])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    func testMixedConversationsExcludeArchivedAndWorkspaceLocalRecordsAndSearchContent() {
        let visible = record(at: Date(), title: "Review", turns: [turn(answer: "Sidebar spacing")])
        var archived = record(at: Date(), title: "Review", turns: [turn(answer: "Sidebar spacing")])
        archived.archivedAt = Date()
        var projectChat = record(at: Date(), title: "Review", turns: [turn(answer: "Sidebar spacing")])
        projectChat.workspaceID = UUID()
        let rows = MarrMixedConversationContent.rows(local: [archived, projectChat, visible], codex: [], query: "spacing")
        XCTAssertEqual(rows.map(\.id), ["local-" + visible.id.uuidString])
        XCTAssertTrue(MarrMixedConversationContent.rows(local: [visible], codex: [], query: "absent").isEmpty)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0,
                      calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    private func record(id: UUID = UUID(), at date: Date, title: String? = nil,
                        turns: [ConversationTurn] = []) -> ConversationHistoryRecord {
        ConversationHistoryRecord(id: id, createdAt: date, updatedAt: date, generatedTitle: title,
                                  turns: turns, images: [], pendingImageIDs: [])
    }

    private func turn(question: String = "", answer: String = "", error: String? = nil,
                      status: ConversationTurnStatus = .completed) -> ConversationTurn {
        ConversationTurn(id: UUID(), question: question, imageIDs: [], answer: answer,
                         errorMessage: error, status: status, showsAssistant: true)
    }
}
