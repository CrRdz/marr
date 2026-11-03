import Foundation
import Combine
import MarrCore

@MainActor
final class PersonalAgentStore: ObservableObject {
    @Published private(set) var archive: PersonalAgentArchive
    @Published private(set) var errorMessage: String?
    let rootURL: URL?
    private var isReadable = true
    private var archiveURL: URL? { rootURL?.appendingPathComponent("agents-v1.json") }

    init(rootURL: URL? = MarrStorage.rootURL.appendingPathComponent("PersonalAgent", isDirectory: true)) {
        self.rootURL = rootURL
        archive = PersonalAgentArchive()
        guard let url = archiveURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode(PersonalAgentArchive.self, from: Data(contentsOf: url))
            guard saved.version == 1 else { throw PersonalAgentFailure.message("This agent archive needs a newer version of Marr.") }
            archive = saved
            // A lost connection is never evidence that remote work stopped.
            for index in archive.runs.indices where archive.runs[index].status.isInFlight {
                if archive.runs[index].submissionAttempted == false {
                    archive.runs[index].status = .cancelled
                    archive.runs[index].finishedAt = Date()
                    archive.runs[index].detail = "Marr restarted before this run was submitted. No work was sent."
                } else {
                    archive.runs[index].status = .uncertain
                    archive.runs[index].detail = "Marr restarted during this run. Check its state before running more work."
                }
            }
        } catch {
            isReadable = false
            archive = PersonalAgentArchive(agents: [])
            errorMessage = "Could not read Personal Agent data. The original file was preserved. \(error.localizedDescription)"
        }
    }

    /// Publish only after an atomic write succeeds. No execution starts without
    /// a durable run record, and a corrupt archive is never replaced by defaults.
    func update(_ change: (inout PersonalAgentArchive) throws -> Void) throws {
        guard isReadable else { throw PersonalAgentFailure.message(errorMessage ?? "Agent storage is unavailable.") }
        var next = archive
        try change(&next)
        do {
            if let url = archiveURL {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(next).write(to: url, options: .atomic)
            }
            archive = next
            errorMessage = nil
        } catch {
            errorMessage = "Could not save Personal Agent data: \(error.localizedDescription)"
            throw error
        }
    }

    func save(_ agent: PersonalAgentProfile) throws {
        guard !agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...60).contains(agent.maxRunMinutes), (1...100).contains(agent.dailyRoutineLimit) else {
            throw PersonalAgentFailure.message("Add a name and instructions, and choose valid run limits.")
        }
        try update { data in
            if let index = data.agents.firstIndex(where: { $0.id == agent.id }) {
                var edited = agent
                edited.threadID = data.agents[index].threadID
                data.agents[index] = edited
            } else { data.agents.append(agent) }
        }
    }

    func save(_ skill: PersonalAgentSkill) throws {
        guard !skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersonalAgentFailure.message("Add a skill name and its instructions.")
        }
        try update { data in
            if let index = data.skills.firstIndex(where: { $0.id == skill.id }) { data.skills[index] = skill }
            else { data.skills.append(skill) }
        }
    }

    func save(_ routine: PersonalAgentRoutine, now: Date = Date()) throws {
        guard archive.agents.contains(where: { $0.id == routine.agentID }),
              !routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !routine.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              routine.schedule.isValid else { throw PersonalAgentFailure.message("Add a name, instruction, agent and valid schedule.") }
        try update { data in
            var edited = routine
            let old = data.routines.first { $0.id == routine.id }
            edited.threadID = old?.threadID
            if old?.schedule != routine.schedule || old?.isEnabled != routine.isEnabled || edited.nextRunAt == nil {
                edited.nextRunAt = routine.isEnabled ? routine.schedule.next(after: now) : nil
            }
            if let index = data.routines.firstIndex(where: { $0.id == routine.id }) { data.routines[index] = edited }
            else { data.routines.append(edited) }
        }
    }

    func workspaceURL(for agentID: UUID) throws -> URL {
        guard let rootURL else { throw PersonalAgentFailure.message("This preview has no execution folder.") }
        let url = rootURL.appendingPathComponent("Workspaces/\(agentID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func updateRun(_ id: UUID, _ change: (inout PersonalAgentRun) -> Void) throws {
        try update { data in
            guard let index = data.runs.firstIndex(where: { $0.id == id }) else { return }
            change(&data.runs[index])
        }
    }

    func dueRoutine(now: Date) -> PersonalAgentRoutine? {
        archive.routines.filter { routine in
            guard routine.isEnabled, let next = routine.nextRunAt, next <= now,
                  let agent = archive.agents.first(where: { $0.id == routine.agentID }), !agent.isPaused,
                  !archive.runs.contains(where: { $0.agentID == agent.id && ($0.status.isInFlight || $0.status == .uncertain) }) else { return false }
            let recent = archive.runs.filter { $0.agentID == agent.id && $0.routineID != nil && $0.startedAt > now.addingTimeInterval(-86_400) }
            return recent.count < agent.dailyRoutineLimit
        }.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }.first
    }

    func begin(agentID: UUID, prompt: String, routineID: UUID? = nil, scheduled: Bool = false,
               now: Date = Date()) throws -> PersonalAgentRun {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let agent = archive.agents.first(where: { $0.id == agentID }), !agent.isPaused else {
            throw PersonalAgentFailure.message("Choose an active agent and enter a message.")
        }
        guard !archive.runs.contains(where: { $0.status.isInFlight || ($0.agentID == agentID && $0.status == .uncertain) }) else {
            throw PersonalAgentFailure.message("Finish the current run or check its connection before starting another.")
        }
        let routine = archive.routines.first { $0.id == routineID }
        if let routineID {
            guard let routine, routine.agentID == agentID,
                  !scheduled || (routine.isEnabled && routine.nextRunAt.map { $0 <= now } == true),
                  archive.runs.filter({ $0.agentID == agentID && $0.routineID != nil && $0.startedAt > now.addingTimeInterval(-86_400) }).count < agent.dailyRoutineLimit else {
                throw PersonalAgentFailure.message("This routine is unavailable, not due, or has reached its daily run limit (\(routineID)).")
            }
        }
        let run = PersonalAgentRun(agentID: agentID, routineID: routineID, prompt: prompt, startedAt: now,
                                   threadID: routineID == nil ? agent.threadID : routine?.threadID)
        try update { data in
            data.runs.append(run)
            if scheduled, let index = data.routines.firstIndex(where: { $0.id == routineID }) {
                data.routines[index].nextRunAt = data.routines[index].schedule.next(after: now)
            }
        }
        return run
    }
}
