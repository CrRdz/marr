import Foundation
import XCTest
@testable import Marr

@MainActor
final class PersonalAgentStoreTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marr-personal-agent-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDailyAndWeekdaySchedulesKeepLocalTimeAcrossDSTAndWeekend() {
        let daily = PersonalAgentSchedule(frequency: .daily, hour: 9, minute: 15, timeZoneID: "America/New_York")
        XCTAssertEqual(daily.next(after: date("2026-03-07T14:15:00Z")), date("2026-03-08T13:15:00Z"))
        let weekdays = PersonalAgentSchedule(frequency: .weekdays, hour: 9, minute: 0, timeZoneID: "Asia/Shanghai")
        XCTAssertEqual(weekdays.next(after: date("2026-10-23T01:00:00Z")), date("2026-10-26T01:00:00Z"))
        XCTAssertNil(PersonalAgentSchedule(timeZoneID: "Invalid/Zone").next(after: Date()))
        XCTAssertNil(PersonalAgentSchedule(hour: 24).next(after: Date()))
    }

    func testHourlyScheduleWaitsForNextOccurrence() {
        let schedule = PersonalAgentSchedule(frequency: .hourly, minute: 10, timeZoneID: "UTC")
        XCTAssertEqual(schedule.next(after: date("2026-10-28T03:10:00Z")), date("2026-10-28T04:10:00Z"))
    }

    func testArchiveRoundTripPreservesIdentitySkillsMemoryAndMarksInterruptedRunUncertain() throws {
        let root = try directory()
        let store = PersonalAgentStore(rootURL: root)
        var agent = try XCTUnwrap(store.archive.agents.first)
        agent.memory = "Prefer short Chinese briefs."
        let skill = PersonalAgentSkill(name: "Verify", instructions: "Check primary sources.")
        agent.skillIDs = [skill.id]
        try store.save(skill); try store.save(agent)
        let run = try store.begin(agentID: agent.id, prompt: "Research this")
        try store.updateRun(run.id) { $0.threadID = "agent-thread"; $0.turnID = "turn-1"; $0.submissionAttempted = true }
        let loaded = PersonalAgentStore(rootURL: root)
        XCTAssertEqual(loaded.archive.agents.first, agent)
        XCTAssertEqual(loaded.archive.skills, [skill])
        XCTAssertEqual(loaded.archive.runs.first?.status, .uncertain)
        XCTAssertEqual(loaded.archive.runs.first?.threadID, "agent-thread")
        XCTAssertThrowsError(try loaded.begin(agentID: agent.id, prompt: "Do it again"))
    }

    func testCorruptArchiveIsPreservedAndCannotBeOverwritten() throws {
        let root = try directory(), url = root.appendingPathComponent("agents-v1.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        let store = PersonalAgentStore(rootURL: root)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.save(PersonalAgentProfile()))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testRestartBeforeSubmissionDoesNotLeaveAgentPermanentlyBlocked() throws {
        let root = try directory(), store = PersonalAgentStore(rootURL: root)
        let agent = store.archive.agents[0]
        let run = try store.begin(agentID: agent.id, prompt: "Not yet sent")
        try store.updateRun(run.id) { $0.threadID = "existing-agent-thread" }
        let restored = PersonalAgentStore(rootURL: root)
        XCTAssertEqual(restored.archive.runs[0].status, .cancelled)
        XCTAssertNoThrow(try restored.begin(agentID: agent.id, prompt: "New work"))
    }

    func testFailedSaveDoesNotPublishOrStartRun() throws {
        let root = try directory().appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: root)
        let store = PersonalAgentStore(rootURL: root)
        let original = store.archive
        XCTAssertThrowsError(try store.begin(agentID: original.agents[0].id, prompt: "Work"))
        XCTAssertEqual(store.archive, original)
    }

    func testDueRunsCoalesceMissedSchedulesAndCannotRunTwice() throws {
        let store = PersonalAgentStore(rootURL: nil), agent = try XCTUnwrap(store.archive.agents.first)
        let before = date("2026-10-20T02:00:00Z"), now = date("2026-10-28T03:00:00Z")
        var routine = PersonalAgentRoutine(agentID: agent.id, name: "Brief", instruction: "Summarize", schedule: PersonalAgentSchedule(timeZoneID: "UTC"), isEnabled: true)
        try store.save(routine, now: before)
        routine = try XCTUnwrap(store.dueRoutine(now: now))
        let run = try store.begin(agentID: agent.id, prompt: routine.instruction, routineID: routine.id, scheduled: true, now: now)
        XCTAssertNil(store.dueRoutine(now: now))
        XCTAssertThrowsError(try store.begin(agentID: agent.id, prompt: routine.instruction, routineID: routine.id, scheduled: true, now: now))
        try store.updateRun(run.id) { $0.status = .succeeded }
        XCTAssertNil(store.dueRoutine(now: now))
        XCTAssertEqual(store.archive.routines.first?.nextRunAt, date("2026-10-28T09:00:00Z"))
    }

    func testPausedAgentAndRollingRunBudgetBlockAutomaticExecution() throws {
        let store = PersonalAgentStore(rootURL: nil)
        var agent = try XCTUnwrap(store.archive.agents.first)
        agent.dailyRoutineLimit = 1; try store.save(agent)
        let now = date("2026-10-28T12:00:00Z")
        let routine = PersonalAgentRoutine(agentID: agent.id, name: "Brief", instruction: "Check", isEnabled: true)
        try store.save(routine, now: now.addingTimeInterval(-100_000))
        agent.isPaused = true; try store.save(agent)
        XCTAssertNil(store.dueRoutine(now: now))
        agent.isPaused = false; try store.save(agent)
        XCTAssertNotNil(store.dueRoutine(now: now))
        let run = try store.begin(agentID: agent.id, prompt: "Check", routineID: routine.id, now: now)
        try store.updateRun(run.id) { $0.status = .succeeded }
        XCTAssertNil(store.dueRoutine(now: now.addingTimeInterval(60)))
        XCTAssertThrowsError(try store.begin(agentID: agent.id, prompt: "Check", routineID: routine.id, now: now))
        XCTAssertNotNil(store.dueRoutine(now: now.addingTimeInterval(86_401)))
    }

    func testScheduleEditsResetNextWakeButManualTestDoesNotMoveIt() throws {
        let store = PersonalAgentStore(rootURL: nil), agent = store.archive.agents[0]
        let now = date("2026-10-28T03:00:00Z")
        var routine = PersonalAgentRoutine(agentID: agent.id, name: "Brief", instruction: "Check", schedule: PersonalAgentSchedule(timeZoneID: "UTC"), isEnabled: true)
        try store.save(routine, now: now)
        let next = store.archive.routines[0].nextRunAt
        let run = try store.begin(agentID: agent.id, prompt: "Check", routineID: routine.id, now: now)
        XCTAssertEqual(store.archive.routines[0].nextRunAt, next)
        try store.updateRun(run.id) { $0.status = .succeeded }
        routine.schedule.hour = 11; try store.save(routine, now: now)
        XCTAssertEqual(store.archive.routines[0].nextRunAt, date("2026-10-28T11:00:00Z"))
        routine.isEnabled = false; try store.save(routine, now: now)
        XCTAssertNil(store.archive.routines[0].nextRunAt)
    }
}
