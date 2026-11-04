import Foundation
import MarrCore
import Combine

@MainActor
final class WorkbenchStore: ObservableObject {
    @Published private(set) var workspaces: [SavedWorkspace] = [] { didSet { sidebarProjectCache = nil; sidebarWorkspaceCache = nil; orderedTaskCache.removeAll(keepingCapacity: true) } }
    @Published private(set) var tasks: [SavedTask] = [] { didSet { sidebarProjectCache = nil; sidebarWorkspaceCache = nil; orderedTaskCache.removeAll(keepingCapacity: true) } }
    @Published private(set) var selectedWorkspaceID: UUID?
    @Published private(set) var selectedTaskID: UUID?
    @Published private(set) var pinnedTaskIDs: Set<UUID> = [] { didSet { orderedTaskCache.removeAll(keepingCapacity: true) } }
    @Published private(set) var taskOrderIDs: [UUID] = [] { didSet { orderedTaskCache.removeAll(keepingCapacity: true) } }

    static let pinnedSectionID = "01984de2-8f74-7c91-a3b2-5c5e937cf318"
    @Published private(set) var desktopSidebarPreferences: CodexDesktopSidebarSnapshot? { didSet { sidebarProjectCache = nil; sidebarWorkspaceCache = nil; orderedTaskCache.removeAll(keepingCapacity: true) } }
    @Published private(set) var supportsSharedSections = false
    private var sharedPinnedOrder: [String] = []
    private var sidebarProjectCache: [SavedWorkspace]?
    private(set) var sidebarProjectBuildCount = 0
    private var sidebarWorkspaceCache: [UUID: UUID]?
    private var orderedTaskCache: [UUID: [SavedTask]] = [:]
    private let defaults: UserDefaults
    private let archiveWriter: WorkbenchArchiveWriter
    private let archiveURL: URL?
    private let storageKey = "codex.workbench.v1"
    private let archivedTaskIDsKey = "codex.workbench.archived-task-ids.v1"
    private let pinnedTaskIDsKey = "codex.workbench.pinned-task-ids.v1"
    private let taskOrderIDsKey = "codex.workbench.task-order.v1"
    private var archivedTaskIDs: Set<UUID> = [] { didSet { orderedTaskCache.removeAll(keepingCapacity: true) } }

    init(defaults: UserDefaults = .standard, archiveURL: URL? = nil) {
        self.defaults = defaults
        let productionURL: URL? = defaults === UserDefaults.standard && ProcessInfo.processInfo.environment["MARR_TEST_HOST"] != "1"
            ? MarrStorage.rootURL.appendingPathComponent("CodexWorkbench/workbench-v1.json") : nil
        self.archiveURL = archiveURL ?? productionURL
        archiveWriter = WorkbenchArchiveWriter(defaults: defaults, key: "codex.workbench.v1", archiveURL: self.archiveURL)
        archivedTaskIDs = Set(
            (defaults.stringArray(forKey: archivedTaskIDsKey) ?? []).compactMap(UUID.init(uuidString:))
        )
        pinnedTaskIDs = Set((defaults.stringArray(forKey: pinnedTaskIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
        taskOrderIDs = (defaults.stringArray(forKey: taskOrderIDsKey) ?? []).compactMap(UUID.init(uuidString:))
        restore()
        normalizeTaskOrder()
        saveTaskOrderIDs()
    }

    var selectedWorkspace: SavedWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedTask: SavedTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    /// Merge the authoritative Codex project catalog without changing the user's selection
    /// or discarding already granted sandbox bookmarks.
    func importProjects(_ projects: [[String: Any]]) {
        for project in projects {
            let name = project["name"] as? String
            let roots = project["roots"] as? [[String: Any]] ?? []
            let id = project["id"] as? String
            for root in id == nil ? roots : Array(roots.prefix(1)) {
                guard let path = root["path"] as? String, path.hasPrefix("/") else { continue }
                let workspace = ensureWorkspace(url: URL(fileURLWithPath: path), name: name)
                if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                    workspaces[index].projectID = id
                    workspaces[index].projectPosition = project["position"] as? Int
                    workspaces[index].projectRecencyAt = (project["recencyAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                }
            }
        }
        orderedTaskCache.removeAll(keepingCapacity: true)
        sortWorkspaces()
        if let preferences = desktopSidebarPreferences { applyDesktopSidebarPreferences(preferences) }
        save(wait: false)
    }

    var sidebarWorkspaces: [SavedWorkspace] {
        if let cached = sidebarProjectCache { return cached }
        sidebarProjectBuildCount += 1
        let result: [SavedWorkspace]
        if workspaces.contains(where: { $0.projectID != nil }) {
            let legacyWorkspaceIDs = Set(tasks.lazy.filter { $0.hasCanonicalProject != true }.map(\.workspaceID))
            result = workspaces.filter {
                $0.projectID != nil || legacyWorkspaceIDs.contains($0.id) || !$0.bookmark.isEmpty
            }
        } else { result = workspaces }
        sidebarProjectCache = result
        return result
    }

    func task(_ task: SavedTask, belongsTo project: SavedWorkspace) -> Bool {
        sidebarWorkspaceID(for: task) == project.id
    }

    func sidebarWorkspaceID(for task: SavedTask) -> UUID? {
        if sidebarWorkspaceCache == nil {
            let projects = workspaces.filter { $0.projectID != nil }
            let canonical = Dictionary(projects.map { ($0.projectID!, $0.id) }, uniquingKeysWith: { first, _ in first })
            let paths = Dictionary(workspaces.map { ($0.id, URL(fileURLWithPath: $0.path).standardizedFileURL.path) }, uniquingKeysWith: { first, _ in first })
            let roots = projects.flatMap { project -> [(String, UUID)] in
                let saved = desktopSidebarPreferences?.projects.first { $0.id == project.projectID }?.roots ?? [project.path]
                return saved.map { (URL(fileURLWithPath: $0).standardizedFileURL.path, project.id) }
            }.sorted { $0.0.count > $1.0.count }
            let projectless = Set(desktopSidebarPreferences?.projectlessThreadIDs ?? [])
            var resolved: [UUID: UUID] = [:]
            for item in tasks {
                if let id = item.projectID { resolved[item.id] = canonical[id]; continue }
                if item.isExplicitlyProjectless == true { continue }
                let thread = item.threadID ?? ""
                if projectless.contains(thread) { continue }
                if let id = desktopSidebarPreferences?.threadProjects?[thread] {
                    resolved[item.id] = canonical[id]; continue
                }
                // Null projectId is common on legacy desktop conversations.
                // Root hints also retain the owning project for worktree chats.
                let path = desktopSidebarPreferences?.threadWorkspaceRoots?[thread] ?? paths[item.workspaceID]
                if let path, let match = roots.first(where: { path == $0.0 || path.hasPrefix($0.0 == "/" ? "/" : $0.0 + "/") }) {
                    resolved[item.id] = match.1
                } else if item.hasCanonicalProject != true { resolved[item.id] = item.workspaceID }
            }
            sidebarWorkspaceCache = resolved
        }
        return sidebarWorkspaceCache?[task.id]
    }

    /// Keep execution cwd/workspace separate from sidebar project membership.
    /// Missing fields preserve local metadata; null clears the canonical ID,
    /// while legacy desktop membership can still resolve the sidebar project.
    func importThreadSidebarMetadata(_ thread: [String: Any]) {
        guard let threadID = thread["id"] as? String,
              let index = tasks.firstIndex(where: { $0.threadID == threadID }) else { return }
        var task = tasks[index]
        if thread.keys.contains("projectId") {
            task.hasCanonicalProject = true
            task.projectID = thread["projectId"] as? String
            if task.projectID != nil { task.isExplicitlyProjectless = false }
        }
        if let explicit = thread["marrExplicitProjectless"] as? Bool { task.isExplicitlyProjectless = explicit }
        if thread.keys.contains("section") {
            supportsSharedSections = true
            task.sectionID = (thread["section"] as? [String: Any])?["id"] as? String
            setTaskPinned(task.id, pinned: task.sectionID == Self.pinnedSectionID)
        }
        if tasks[index] != task { tasks[index] = task; save(wait: false) }
    }

    func setTaskPinned(_ id: UUID, pinned: Bool) {
        guard pinnedTaskIDs.contains(id) != pinned else { return }
        if pinned { pinnedTaskIDs.insert(id) } else { pinnedTaskIDs.remove(id) }
        savePinnedTaskIDs()
    }

    func setSharedPinnedOrder(_ threadIDs: [String]) {
        guard sharedPinnedOrder != threadIDs else { return }
        sharedPinnedOrder = threadIDs
        orderedTaskCache.removeAll(keepingCapacity: true)
        objectWillChange.send()
    }

    var pinnedSidebarTasks: [SavedTask] {
        let ranks = Dictionary(sharedPinnedOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return tasks.filter { isTaskPinned($0.id) && !isTaskArchived($0.id) }.sorted {
            if desktopSidebarPreferences?.pinnedSort == "updated_at" { return $0.updatedAt > $1.updatedAt }
            let a = ranks[$0.threadID ?? ""] ?? Int.max, b = ranks[$1.threadID ?? ""] ?? Int.max
            return a != b ? a < b : $0.updatedAt > $1.updatedAt
        }
    }

    func clearDesktopSidebarPreferences() {
        desktopSidebarPreferences = nil
        orderedTaskCache.removeAll(keepingCapacity: true)
    }

    func applyDesktopSidebarPreferences(_ preferences: CodexDesktopSidebarSnapshot) {
        if let previous = desktopSidebarPreferences {
            for index in tasks.indices {
                guard tasks[index].isExplicitlyProjectless == true, let thread = tasks[index].threadID else { continue }
                if previous.threadProjects?[thread] != preferences.threadProjects?[thread]
                    || (previous.projectlessThreadIDs ?? []).contains(thread) != (preferences.projectlessThreadIDs ?? []).contains(thread) {
                    tasks[index].isExplicitlyProjectless = false
                }
            }
        }
        desktopSidebarPreferences = preferences
        let pins = Set(preferences.pinnedProjectIDs)
        for index in workspaces.indices {
            if let id = workspaces[index].projectID {
                workspaces[index].isPinned = workspaces[index].pinOverride ?? pins.contains(id)
            }
        }
        orderedTaskCache.removeAll(keepingCapacity: true)
        sortWorkspaces()
        save(wait: false)
    }

    /// Register a discovered root without switching the current task or its access grant.
    @discardableResult
    func ensureWorkspace(url: URL, name: String? = nil) -> SavedWorkspace {
        let normalizedURL = url.standardizedFileURL
        let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = workspaces.firstIndex(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedURL.path
        }) {
            let previous = workspaces[index]
            if let displayName, !displayName.isEmpty { workspaces[index].name = displayName }
            workspaces[index].path = normalizedURL.path
            if workspaces[index] != previous { save() }
            return workspaces[index]
        }

        let workspace = SavedWorkspace(
            id: UUID(),
            name: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? normalizedURL.lastPathComponent,
            path: normalizedURL.path,
            bookmark: Data(),
            lastUsedAt: .distantPast
        )
        workspaces.append(workspace)
        sortWorkspaces()
        save()
        return workspace
    }

    func upsertWorkspace(url: URL, bookmark: Data) -> SavedWorkspace {
        let workspace = ensureWorkspace(url: url)
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index].bookmark = bookmark
        }
        selectWorkspace(workspace.id)
        return workspaces.first { $0.id == workspace.id }!
    }

    func selectWorkspace(_ id: UUID, persistAsynchronously: Bool = false) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        validateSelection()
        if let index = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[index].lastUsedAt = Date()
            sortWorkspaces()
        }
        save(wait: !persistAsynchronously)
    }

    func clearSelectedTask() {
        selectedTaskID = nil
        save()
    }

    func toggleWorkspacePinned(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].isPinned.toggle()
        workspaces[index].pinOverride = workspaces[index].isPinned
        sortWorkspaces()
        save()
    }

    func followDesktopWorkspacePin(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              let project = workspaces[index].projectID, let preferences = desktopSidebarPreferences else { return }
        workspaces[index].pinOverride = nil
        workspaces[index].isPinned = preferences.pinnedProjectIDs.contains(project)
        sortWorkspaces()
        save()
    }

    func isTaskArchived(_ id: UUID) -> Bool {
        archivedTaskIDs.contains(id)
    }

    func isTaskPinned(_ id: UUID) -> Bool { pinnedTaskIDs.contains(id) }

    /// Manual ordering is local to this workbench. Pinning remains the outer
    /// grouping, and each project remains independent of every other project.
    func orderedTasks(in workspaceID: UUID) -> [SavedTask] {
        if let cached = orderedTaskCache[workspaceID] { return cached }
        let ranks = Dictionary(uniqueKeysWithValues: taskOrderIDs.enumerated().map { ($0.element, $0.offset) })
        let project = workspaces.first { $0.id == workspaceID }
        let desktopOrder = project?.projectID.flatMap { desktopSidebarPreferences?.taskOrder[$0] } ?? []
        let sharedRanks = Dictionary(desktopOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let ordered = tasks.filter { item in
            !isTaskArchived(item.id) && (project.map { task(item, belongsTo: $0) } ?? false)
        }.sorted {
            let leftPinned = isTaskPinned($0.id)
            let rightPinned = isTaskPinned($1.id)
            if leftPinned != rightPinned { return leftPinned }
            let followsDesktop = desktopSidebarPreferences != nil
            let manual = desktopSidebarPreferences?.chatSort == "manual"
            let leftRank = followsDesktop ? (manual ? sharedRanks[$0.threadID ?? ""] ?? Int.max : Int.max) : ranks[$0.id] ?? Int.max
            let rightRank = followsDesktop ? (manual ? sharedRanks[$1.threadID ?? ""] ?? Int.max : Int.max) : ranks[$1.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        orderedTaskCache[workspaceID] = ordered
        return ordered
    }

    func canMoveTask(_ id: UUID, direction: TaskMoveDirection) -> Bool {
        adjacentTask(to: id, direction: direction) != nil
    }

    @discardableResult
    func moveTask(_ id: UUID, direction: TaskMoveDirection) -> Bool {
        guard let target = adjacentTask(to: id, direction: direction) else { return false }
        return moveTask(id, relativeTo: target.id, placement: direction == .up ? .before : .after)
    }

    @discardableResult
    func moveTask(_ id: UUID, relativeTo targetID: UUID, placement: TaskPlacement) -> Bool {
        guard id != targetID,
              let source = tasks.first(where: { $0.id == id }),
              let target = tasks.first(where: { $0.id == targetID }),
              source.workspaceID == target.workspaceID,
              isTaskPinned(id) == isTaskPinned(targetID),
              !isTaskArchived(id), !isTaskArchived(targetID)
        else { return false }
        let group = orderedTasks(in: source.workspaceID).filter { isTaskPinned($0.id) == isTaskPinned(id) }
        guard !group.contains(where: { $0.state == .running }) else { return false }
        var reordered = group.map(\.id).filter { $0 != id }
        guard let targetIndex = reordered.firstIndex(of: targetID) else { return false }
        reordered.insert(id, at: targetIndex + (placement == .after ? 1 : 0))
        guard reordered != group.map(\.id) else { return false }

        // Only the moved group enters manual order. Other groups retain their
        // existing recency behavior until the user explicitly reorders them.
        let groupIDs = Set(reordered)
        taskOrderIDs.removeAll { groupIDs.contains($0) }
        taskOrderIDs.append(contentsOf: reordered)
        saveTaskOrderIDs()
        return true
    }

    private func adjacentTask(to id: UUID, direction: TaskMoveDirection) -> SavedTask? {
        guard let task = tasks.first(where: { $0.id == id }), !isTaskArchived(id) else { return nil }
        let group = orderedTasks(in: task.workspaceID).filter { isTaskPinned($0.id) == isTaskPinned(id) }
        guard !group.contains(where: { $0.state == .running }),
              let index = group.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + (direction == .up ? -1 : 1)
        return group.indices.contains(target) ? group[target] : nil
    }

    func toggleTaskPinned(_ id: UUID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        if !pinnedTaskIDs.insert(id).inserted { pinnedTaskIDs.remove(id) }
        savePinnedTaskIDs()
    }

    @discardableResult
    func renameTask(_ id: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].title = name
        tasks[index].updatedAt = Date()
        tasks.sort { $0.updatedAt > $1.updatedAt }
        save()
        return true
    }

    func archiveTasks(in workspaceID: UUID) {
        archivedTaskIDs.formUnion(tasks.filter { $0.workspaceID == workspaceID }.map(\.id))
        validateSelection()
        save()
        saveArchivedTaskIDs()
    }

    func archiveTask(_ id: UUID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        archivedTaskIDs.insert(id)
        validateSelection()
        save()
        saveArchivedTaskIDs()
    }

    func unarchiveTask(_ id: UUID) {
        archivedTaskIDs.remove(id)
        saveArchivedTaskIDs()
    }

    func removeWorkspace(_ id: UUID) {
        let removedTaskIDs = Set(tasks.filter { $0.workspaceID == id }.map(\.id))
        workspaces.removeAll { $0.id == id }
        tasks.removeAll { $0.workspaceID == id }
        archivedTaskIDs.subtract(removedTaskIDs)
        pinnedTaskIDs.subtract(removedTaskIDs)
        taskOrderIDs.removeAll { removedTaskIDs.contains($0) }
        if selectedWorkspaceID == id { selectedWorkspaceID = nil }
        if let selectedTaskID, removedTaskIDs.contains(selectedTaskID) { self.selectedTaskID = nil }
        saveArchivedTaskIDs()
        savePinnedTaskIDs()
        saveTaskOrderIDs()
        save()
    }

    func createTask(workspaceID: UUID, prompt: String) -> SavedTask {
        let now = Date()
        let task = SavedTask(
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
        // New local chats appear first even after their group was reordered.
        if tasks.contains(where: {
            $0.workspaceID == workspaceID && !isTaskPinned($0.id) && taskOrderIDs.contains($0.id)
        }) {
            taskOrderIDs.insert(task.id, at: 0)
            saveTaskOrderIDs()
        }
        selectedWorkspaceID = workspaceID
        selectedTaskID = task.id
        save()
        return task
    }

    @discardableResult
    func upsertRemoteTask(
        workspaceID: UUID,
        threadID: String,
        title: String,
        state: SavedTaskState,
        statusMessage: String,
        createdAt: Date,
        updatedAt: Date,
        persistAsynchronously: Bool = false
    ) -> SavedTask {
        let existing = tasks.filter { $0.threadID == threadID }
        let retainedTask = existing.first { $0.id == selectedTaskID } ?? existing.first
        if let retainedTask, let index = tasks.firstIndex(where: { $0.id == retainedTask.id }) {
            let taskID = tasks[index].id
            tasks[index].workspaceID = workspaceID
            tasks[index].title = title.isEmpty ? tasks[index].title : title
            tasks[index].state = state
            tasks[index].statusMessage = statusMessage
            tasks[index].updatedAt = updatedAt
            // Older archives keyed threads by (workspace, thread), so moving a thread
            // could leave several local copies. Keep its selected identity and cache.
            let duplicateIDs = Set(existing.filter { $0.id != taskID }.map(\.id))
            if existing.contains(where: { archivedTaskIDs.contains($0.id) }) {
                archivedTaskIDs.insert(taskID)
            }
            if existing.contains(where: { pinnedTaskIDs.contains($0.id) }) { pinnedTaskIDs.insert(taskID) }
            tasks.removeAll { duplicateIDs.contains($0.id) }
            archivedTaskIDs.subtract(duplicateIDs)
            pinnedTaskIDs.subtract(duplicateIDs)
            if let firstRank = taskOrderIDs.firstIndex(where: { duplicateIDs.contains($0) || $0 == taskID }) {
                taskOrderIDs.insert(taskID, at: firstRank)
            }
            normalizeTaskOrder()
            saveTaskOrderIDs()
            validateSelection()
            tasks.sort { $0.updatedAt > $1.updatedAt }
            saveArchivedTaskIDs()
            savePinnedTaskIDs()
            save(wait: !persistAsynchronously)
            return tasks.first { $0.id == taskID }!
        }

        let task = SavedTask(
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
        save(wait: !persistAsynchronously)
        return task
    }

    func selectTask(_ id: UUID, persistAsynchronously: Bool = false) {
        guard let task = tasks.first(where: { $0.id == id }),
              !archivedTaskIDs.contains(id),
              let workspaceIndex = workspaces.firstIndex(where: { $0.id == task.workspaceID })
        else { return }
        selectedWorkspaceID = task.workspaceID
        selectedTaskID = id
        workspaces[workspaceIndex].lastUsedAt = Date()
        sortWorkspaces()
        save(wait: !persistAsynchronously)
    }

    func updateTask(
        id: UUID,
        threadID: String? = nil,
        state: SavedTaskState? = nil,
        statusMessage: String? = nil,
        latestAgentMessage: String? = nil,
        latestDiff: String? = nil,
        activities: [WorkActivity]? = nil,
        persistAsynchronously: Bool = false,
        updatedAt: Date? = nil,
        lastKnownTurnID: String? = nil,
        clearKnownTurnID: Bool = false
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let threadID { tasks[index].threadID = threadID }
        if clearKnownTurnID { tasks[index].lastKnownTurnID = nil }
        else if let lastKnownTurnID { tasks[index].lastKnownTurnID = lastKnownTurnID }
        if let state { tasks[index].state = state }
        if let statusMessage { tasks[index].statusMessage = statusMessage }
        if let latestAgentMessage { tasks[index].latestAgentMessage = latestAgentMessage }
        if let latestDiff { tasks[index].latestDiff = latestDiff }
        if let activities {
            tasks[index].activities = activities.map { activity in
                var cachedActivity = activity
                // Keep every turn and all message text. Limit only bulky execution
                // output in the cache; copying also preserves protocol metadata.
                if activity.kind != .user, activity.kind != .message, activity.detail.count > 12_000 {
                    cachedActivity.detail = String(activity.detail.prefix(12_000))
                        + "\n[Cached output truncated; reload task history for the full result.]"
                }
                return cachedActivity
            }
        }
        tasks[index].updatedAt = updatedAt ?? Date()
        tasks.sort { $0.updatedAt > $1.updatedAt }
        save(wait: !persistAsynchronously)
    }

    func markSelectedTask(_ state: SavedTaskState, statusMessage: String) {
        guard let selectedTaskID else { return }
        updateTask(id: selectedTaskID, state: state, statusMessage: statusMessage)
    }

    private func restore() {
        let fileData = archiveURL.flatMap { try? Data(contentsOf: $0) }
        let fileArchive = fileData.flatMap { try? JSONDecoder().decode(WorkbenchArchive.self, from: $0) }
        let legacyArchive = fileArchive == nil ? defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(WorkbenchArchive.self, from: $0) } : nil
        let backupArchive = fileArchive == nil && legacyArchive == nil ? archiveURL
            .flatMap { try? Data(contentsOf: $0.appendingPathExtension("legacy-backup")) }
            .flatMap { try? JSONDecoder().decode(WorkbenchArchive.self, from: $0) } : nil
        guard let archive = fileArchive ?? legacyArchive ?? backupArchive else { return }
        workspaces = archive.workspaces
        tasks = archive.tasks
        selectedWorkspaceID = archive.selectedWorkspaceID
        selectedTaskID = archive.selectedTaskID
        pinnedTaskIDs.formIntersection(tasks.map(\.id))
        normalizeTaskOrder()
        savePinnedTaskIDs()
        saveTaskOrderIDs()
        validateSelection()
        if selectedWorkspaceID != archive.selectedWorkspaceID || selectedTaskID != archive.selectedTaskID {
            save(wait: archiveURL == nil)
        } else if archiveURL != nil, fileArchive == nil {
            save(wait: false)
        }
    }

    private func validateSelection() {
        if !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = nil
        }
        guard let task = tasks.first(where: { $0.id == selectedTaskID }),
              !archivedTaskIDs.contains(task.id), task.workspaceID == selectedWorkspaceID
        else {
            selectedTaskID = nil
            return
        }
    }

    /// Wait for already queued snapshots before shutdown or reading a fresh store.
    func flushPersistence() { archiveWriter.flush() }

    var persistenceDiagnostics: (writes: Int, encodingOnMainThread: Bool, writesOnMainThread: Bool) { archiveWriter.diagnostics }

    private func save(wait: Bool = true) {
        let archive = WorkbenchArchive(
            workspaces: workspaces,
            tasks: tasks,
            selectedWorkspaceID: selectedWorkspaceID,
            selectedTaskID: selectedTaskID
        )
        // File-backed production saves never hold up navigation or a frame.
        // Explicit flushPersistence at shutdown remains the durability barrier.
        archiveWriter.save(archive, wait: wait && archiveURL == nil)
    }

    private func saveArchivedTaskIDs() {
        defaults.set(archivedTaskIDs.map(\.uuidString), forKey: archivedTaskIDsKey)
    }

    private func savePinnedTaskIDs() {
        defaults.set(pinnedTaskIDs.map(\.uuidString).sorted(), forKey: pinnedTaskIDsKey)
    }

    private func normalizeTaskOrder() {
        let validIDs = Set(tasks.map(\.id))
        var seen = Set<UUID>()
        taskOrderIDs = taskOrderIDs.filter { validIDs.contains($0) && seen.insert($0).inserted }
    }

    private func saveTaskOrderIDs() {
        defaults.set(taskOrderIDs.map(\.uuidString), forKey: taskOrderIDsKey)
    }

    private func sortWorkspaces() {
        let preferences = desktopSidebarPreferences
        let order = Dictionary((preferences?.projectOrder ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let pins = Dictionary((preferences?.pinnedProjectIDs ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        workspaces.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if let preferences {
                let ranks = $0.isPinned ? pins : order
                if ($0.isPinned && preferences.pinnedSort == "manual") || (!$0.isPinned && preferences.projectSort == "manual") {
                    let a = ranks[$0.projectID ?? ""] ?? $0.projectPosition ?? Int.max
                    let b = ranks[$1.projectID ?? ""] ?? $1.projectPosition ?? Int.max
                    if a != b { return a < b }
                }
                let a = $0.projectRecencyAt ?? .distantPast, b = $1.projectRecencyAt ?? .distantPast
                if a != b { return a > b }
            }
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
