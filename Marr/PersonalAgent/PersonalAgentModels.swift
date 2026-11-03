import Foundation

enum PersonalAgentAccess: String, Codable, CaseIterable, Identifiable {
    case readOnly, workspace
    var id: String { rawValue }
    var title: String { self == .readOnly ? "Read only" : "Agent folder" }
    var sandbox: String { self == .readOnly ? "read-only" : "workspace-write" }
}

struct PersonalAgentProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "Marr"
    var role = "Your personal assistant"
    var instructions = "Help me turn intentions into finished work. Verify results, keep useful context, and be clear about what needs my attention."
    var memory = ""
    var access: PersonalAgentAccess = .readOnly
    var skillIDs: [UUID] = []
    var threadID: String?
    var isPaused = false
    var tint = 0
    var maxRunMinutes = 10
    var dailyRoutineLimit = 12
    var createdAt = Date()
}

struct PersonalAgentSkill: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var instructions = ""
}

struct PersonalAgentSchedule: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case hourly, daily, weekdays
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    var frequency: Frequency = .daily
    var hour = 9
    var minute = 0
    var timeZoneID = TimeZone.current.identifier

    var isValid: Bool {
        (0...23).contains(hour) && (0...59).contains(minute) && TimeZone(identifier: timeZoneID) != nil
    }

    /// Calendar matching preserves wall-clock time over DST. Missed occurrences
    /// coalesce into one wake; callers advance from now, never replay a backlog.
    func next(after date: Date) -> Date? {
        guard isValid, let zone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents()
        components.minute = minute
        components.second = 0
        if frequency != .hourly { components.hour = hour }
        var cursor = date
        for _ in 0..<8 {
            guard let next = calendar.nextDate(after: cursor, matching: components,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
            if frequency != .weekdays || !calendar.isDateInWeekend(next) { return next }
            cursor = next
        }
        return nil
    }

    var label: String {
        let time = String(format: "%02d:%02d", hour, minute)
        return frequency == .hourly
            ? "Hourly at :\(String(format: "%02d", minute)) · \(timeZoneID)"
            : "\(frequency.title) at \(time) · \(timeZoneID)"
    }

    func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct PersonalAgentRoutine: Identifiable, Codable, Equatable {
    var id = UUID()
    var agentID: UUID
    var name = ""
    var instruction = ""
    var skillIDs: [UUID] = []
    var schedule = PersonalAgentSchedule()
    var isEnabled = false
    var nextRunAt: Date?
    var threadID: String?
}

struct PersonalAgentTrace: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    var date = Date()
}

struct PersonalAgentRun: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        case running, needsInput, succeeded, failed, cancelled, uncertain
        var title: String {
            switch self {
            case .running: "Working"
            case .needsInput: "Needs you"
            case .succeeded: "Completed"
            case .failed: "Failed"
            case .cancelled: "Stopped"
            case .uncertain: "Check connection"
            }
        }
        var isInFlight: Bool { self == .running || self == .needsInput }
    }
    var id = UUID()
    var agentID: UUID
    var routineID: UUID?
    var prompt: String
    var status: Status = .running
    var startedAt = Date()
    var finishedAt: Date?
    var threadID: String?
    var turnID: String?
    var submissionAttempted: Bool? = false
    var result = ""
    var detail = ""
    var trace: [PersonalAgentTrace] = []
    var isRead = false
}

struct PersonalAgentArchive: Codable, Equatable {
    var version = 1
    var agents: [PersonalAgentProfile] = [PersonalAgentProfile()]
    var skills: [PersonalAgentSkill] = []
    var routines: [PersonalAgentRoutine] = []
    var runs: [PersonalAgentRun] = []
}

enum PersonalAgentFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}
