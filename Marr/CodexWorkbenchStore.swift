import Foundation

struct CodexSavedWorkspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var bookmark: Data
    var lastUsedAt: Date
    var isPinned: Bool

    init(
        id: UUID,
        name: String,
        path: String,
        bookmark: Data,
        lastUsedAt: Date,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, bookmark, lastUsedAt, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

enum CodexSavedTaskState: String, Codable {
    case ready
    case running
    case completed
    case failed
    case interrupted
}

struct CodexSavedTask: Codable, Identifiable, Equatable {
    let id: UUID
    var workspaceID: UUID
    var title: String
    var threadID: String?
    var state: CodexSavedTaskState
    var statusMessage: String
    var latestAgentMessage: String
    var latestDiff: String
    var activities: [CodexActivity]
    var createdAt: Date
    var updatedAt: Date
}

@MainActor
final class CodexWorkbenchStore: ObservableObject {
    @Published private(set) var workspaces: [CodexSavedWorkspace] = []
    @Published private(set) var tasks: [CodexSavedTask] = []
    @Published private(set) var selectedWorkspaceID: UUID?
    @Published private(set) var selectedTaskID: UUID?

    private let defaults: UserDefaults
    private let storageKey = "codex.workbench.v1"
    private let archivedTaskIDsKey = "codex.workbench.archived-task-ids.v1"
    private var archivedTaskIDs: Set<UUID> = []

    private struct Archive: Codable {
        var workspaces: [CodexSavedWorkspace]
        var tasks: [CodexSavedTask]
        var selectedWorkspaceID: UUID?
        var selectedTaskID: UUID?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
        archivedTaskIDs = Set(
            (defaults.stringArray(forKey: archivedTaskIDsKey) ?? []).compactMap(UUID.init(uuidString:))
        )
    }

    var selectedWorkspace: CodexSavedWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedTask: CodexSavedTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    /// Merge the authoritative Codex project catalog without changing the user's selection
    /// or discarding already granted sandbox bookmarks.
    func importProjects(_ projects: [[String: Any]]) {
        for project in projects {
            let name = project["name"] as? String
            for root in project["roots"] as? [[String: Any]] ?? [] {
                guard let path = root["path"] as? String, path.hasPrefix("/") else { continue }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                if let index = workspaces.firstIndex(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == url.path }) {
                    if let name, !name.isEmpty { workspaces[index].name = name }
                } else {
                    workspaces.append(CodexSavedWorkspace(
                        id: UUID(), name: name ?? url.lastPathComponent, path: url.path,
                        bookmark: Data(), lastUsedAt: .distantPast
                    ))
                }
            }
        }
        sortWorkspaces()
        save()
    }

    func upsertWorkspace(url: URL, bookmark: Data) -> CodexSavedWorkspace {
        let now = Date()
        if let index = workspaces.firstIndex(where: { $0.path == url.path }) {
            workspaces[index].name = url.lastPathComponent
            workspaces[index].bookmark = bookmark
            workspaces[index].lastUsedAt = now
            selectedWorkspaceID = workspaces[index].id
            sortWorkspaces()
            save()
            return workspaces.first { $0.id == selectedWorkspaceID }!
        }

        let workspace = CodexSavedWorkspace(
            id: UUID(),
            name: url.lastPathComponent,
            path: url.path,
            bookmark: bookmark,
            lastUsedAt: now
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        sortWorkspaces()
        save()
        return workspaces.first { $0.id == workspace.id }!
    }

    func selectWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        if let index = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[index].lastUsedAt = Date()
            sortWorkspaces()
        }
        save()
    }

    func toggleWorkspacePinned(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].isPinned.toggle()
        sortWorkspaces()
        save()
    }

    func isTaskArchived(_ id: UUID) -> Bool {
        archivedTaskIDs.contains(id)
    }

    func archiveTasks(in workspaceID: UUID) {
        archivedTaskIDs.formUnion(tasks.filter { $0.workspaceID == workspaceID }.map(\.id))
        if let selectedTaskID, archivedTaskIDs.contains(selectedTaskID) {
            self.selectedTaskID = nil
            save()
        }
        saveArchivedTaskIDs()
    }

    func removeWorkspace(_ id: UUID) {
        let removedTaskIDs = Set(tasks.filter { $0.workspaceID == id }.map(\.id))
        workspaces.removeAll { $0.id == id }
        tasks.removeAll { $0.workspaceID == id }
        archivedTaskIDs.subtract(removedTaskIDs)
        if selectedWorkspaceID == id { selectedWorkspaceID = nil }
        if let selectedTaskID, removedTaskIDs.contains(selectedTaskID) { self.selectedTaskID = nil }
        saveArchivedTaskIDs()
        save()
    }

    func createTask(workspaceID: UUID, prompt: String) -> CodexSavedTask {
        let now = Date()
        let task = CodexSavedTask(
            id: UUID(),
            workspaceID: workspaceID,
            title: taskTitle(from: prompt),
            threadID: nil,
            state: .running,
            statusMessage: "Preparing Codex task",
            latestAgentMessage: "",
            latestDiff: "",
            activities: [],
            createdAt: now,
            updatedAt: now
        )
        tasks.insert(task, at: 0)
        selectedTaskID = task.id
        save()
        return task
    }

    @discardableResult
    func upsertRemoteTask(
        workspaceID: UUID,
        threadID: String,
        title: String,
        state: CodexSavedTaskState,
        statusMessage: String,
        createdAt: Date,
        updatedAt: Date
    ) -> CodexSavedTask {
        if let index = tasks.firstIndex(where: {
            $0.workspaceID == workspaceID && $0.threadID == threadID
        }) {
            let taskID = tasks[index].id
            tasks[index].title = title.isEmpty ? tasks[index].title : title
            tasks[index].state = state
            tasks[index].statusMessage = statusMessage
            tasks[index].updatedAt = updatedAt
            tasks.sort { $0.updatedAt > $1.updatedAt }
            save()
            return tasks.first { $0.id == taskID }!
        }

        let task = CodexSavedTask(
            id: UUID(),
            workspaceID: workspaceID,
            title: title.isEmpty ? "Untitled Codex task" : title,
            threadID: threadID,
            state: state,
            statusMessage: statusMessage,
            latestAgentMessage: "",
            latestDiff: "",
            activities: [],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        tasks.insert(task, at: 0)
        tasks.sort { $0.updatedAt > $1.updatedAt }
        save()
        return task
    }

    func selectTask(_ id: UUID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        selectedTaskID = id
        save()
    }

    func updateTask(
        id: UUID,
        threadID: String? = nil,
        state: CodexSavedTaskState? = nil,
        statusMessage: String? = nil,
        latestAgentMessage: String? = nil,
        latestDiff: String? = nil,
        activities: [CodexActivity]? = nil
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let threadID { tasks[index].threadID = threadID }
        if let state { tasks[index].state = state }
        if let statusMessage { tasks[index].statusMessage = statusMessage }
        if let latestAgentMessage { tasks[index].latestAgentMessage = latestAgentMessage }
        if let latestDiff { tasks[index].latestDiff = latestDiff }
        if let activities {
            tasks[index].activities = Array(activities.suffix(80)).map { activity in
                CodexActivity(
                    id: activity.id,
                    kind: activity.kind,
                    title: activity.title,
                    detail: String(activity.detail.prefix(12_000)),
                    isComplete: activity.isComplete,
                    processingSeconds: activity.processingSeconds,
                    turnID: activity.turnID
                )
            }
        }
        tasks[index].updatedAt = Date()
        tasks.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    func markSelectedTask(_ state: CodexSavedTaskState, statusMessage: String) {
        guard let selectedTaskID else { return }
        updateTask(id: selectedTaskID, state: state, statusMessage: statusMessage)
    }

    private func restore() {
        guard let data = defaults.data(forKey: storageKey),
              let archive = try? JSONDecoder().decode(Archive.self, from: data)
        else { return }
        workspaces = archive.workspaces
        tasks = archive.tasks
        selectedWorkspaceID = archive.selectedWorkspaceID
        selectedTaskID = archive.selectedTaskID
    }

    private func save() {
        let archive = Archive(
            workspaces: workspaces,
            tasks: tasks,
            selectedWorkspaceID: selectedWorkspaceID,
            selectedTaskID: selectedTaskID
        )
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func saveArchivedTaskIDs() {
        defaults.set(archivedTaskIDs.map(\.uuidString), forKey: archivedTaskIDsKey)
    }

    private func sortWorkspaces() {
        workspaces.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastUsedAt > $1.lastUsedAt
        }
    }

    private func taskTitle(from prompt: String) -> String {
        let normalized = prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > 54 else { return normalized }
        return String(normalized.prefix(53)) + "…"
    }
}
