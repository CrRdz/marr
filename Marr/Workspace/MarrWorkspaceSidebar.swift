import AppKit
import Foundation
import MarrCore
import SwiftUI

/// A projection of saved Codex projects. It never manufactures a project from
/// a screenshot conversation and does not reorder the workbench's task order.
enum MarrWorkspaceSidebarContent {
    struct Project: Identifiable {
        let workspace: SavedWorkspace
        let tasks: [SavedTask]
        let visibleTasks: [SavedTask]
        let isCollapsed: Bool
        let isExpanded: Bool
        let isSearching: Bool
        var id: UUID { workspace.id }
        var remainingCount: Int { tasks.count - visibleTasks.count }
    }

    static func project(_ workspace: SavedWorkspace, orderedTasks: [SavedTask],
                        searchText: String, isCollapsed: Bool, isExpanded: Bool,
                        previewLimit: Int = 5, membershipResolved: Bool = false) -> Project? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !query.isEmpty
        let projectMatches = workspace.name.localizedCaseInsensitiveContains(query)
            || workspace.path.localizedCaseInsensitiveContains(query)
        let tasks = orderedTasks.filter { task in
            (membershipResolved || (task.hasCanonicalProject == true ? (workspace.projectID != nil && task.projectID == workspace.projectID) : task.workspaceID == workspace.id))
                && (!isSearching || projectMatches || task.title.localizedCaseInsensitiveContains(query))
        }
        guard !isSearching || projectMatches || !tasks.isEmpty else { return nil }
        // Searching reveals matching children without overwriting the user's
        // persisted collapse/show-more choices. Clearing search restores them.
        let collapsed = isCollapsed && !isSearching
        let expanded = isExpanded || isSearching
        return Project(workspace: workspace, tasks: tasks,
                       visibleTasks: collapsed ? [] : expanded ? tasks : Array(tasks.prefix(max(0, previewLimit))),
                       isCollapsed: collapsed, isExpanded: expanded, isSearching: isSearching)
    }

    enum TaskStatus: Equatable {
        case ready, running, savedRunning, loading, checking, unknown, needsInput, completed, failed, interrupted

        var title: String {
            switch self {
            case .ready: "Ready"
            case .running: "Running"
            case .savedRunning: "Last seen running"
            case .loading: "Loading conversation"
            case .checking: "Checking task status"
            case .unknown: "Task status unknown"
            case .needsInput: "Needs your input"
            case .completed: "Completed"
            case .failed: "Failed"
            case .interrupted: "Interrupted"
            }
        }

        var symbol: String? {
            switch self {
            case .ready, .completed: nil
            case .running: "circle.dotted"
            case .savedRunning: "clock.arrow.circlepath"
            case .loading, .checking: "arrow.clockwise"
            case .unknown: "questionmark.circle"
            case .needsInput: "hand.raised"
            case .failed: "exclamationmark.circle"
            case .interrupted: "stop.circle"
            }
        }
    }

    static func status(savedState: SavedTaskState, isSelected: Bool, isRunning: Bool,
                       isRemoteTaskActive: Bool, isReading: Bool, isUncertain: Bool,
                       isReconciling: Bool, needsInput: Bool) -> TaskStatus {
        if isSelected {
            if needsInput { return .needsInput }
            if isUncertain { return isReconciling ? .checking : .unknown }
            if isReconciling { return .checking }
            if isReading { return .loading }
            if isRunning || isRemoteTaskActive { return .running }
        }
        switch savedState {
        case .ready: return .ready
        case .running: return .savedRunning
        case .completed: return .completed
        case .failed: return .failed
        case .interrupted: return .interrupted
        }
    }

    static func switchingBlockReason(isRunning: Bool, isRemoteTaskActive: Bool, isReading: Bool,
                                     isUncertain: Bool, isReconciling: Bool, isRefreshing: Bool) -> String? {
        if isUncertain || isReconciling { return "Wait until the current task's status is confirmed." }
        if isRunning || isRemoteTaskActive { return "Finish or stop the current task before switching conversations." }
        if isReading { return "Wait for the selected conversation to finish loading." }
        if isRefreshing { return "Wait for the workspace refresh to finish." }
        return nil
    }

    static func displayPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        guard !homeDirectory.isEmpty, homeDirectory != "/" else { return path }
        if path == homeDirectory { return "~" }
        guard path.hasPrefix(homeDirectory + "/") else { return path }
        return "~" + path.dropFirst(homeDirectory.count)
    }

    static func needsPathDisambiguation(_ workspace: SavedWorkspace, among workspaces: [SavedWorkspace]) -> Bool {
        workspaces.contains {
            $0.id != workspace.id && $0.name.localizedCaseInsensitiveCompare(workspace.name) == .orderedSame
        }
    }

    static func canPresentRename(targetID: UUID?, selectedID: UUID?, canSubmit: Bool,
                                 canRename: Bool, hasReadError: Bool) -> Bool {
        guard let targetID else { return false }
        return targetID == selectedID && canSubmit && canRename && !hasReadError
    }
}

private enum MarrWorkspaceSidebarFocus: Hashable {
    case project(UUID), projectMenu(UUID), projectNew(UUID), task(UUID), taskMenu(UUID)
}

/// Content only: the owning panel supplies one scroll view for Codex projects
/// and a mixed local/Codex conversation list. Discovery occurs only on clicks.
struct MarrWorkspaceSidebar: View {
    @ObservedObject private var workspace: RuntimeWorkspaceController
    @ObservedObject private var workbench: WorkbenchStore
    @Binding private var searchText: String
    @Binding private var collapsedWorkspaceIDs: Set<UUID>
    @Binding private var expandedWorkspaceIDs: Set<UUID>
    private let isWorkActive: Bool
    private let showsHeader: Bool
    private let onSelectTask: () -> Void
    private let onNewTask: () -> Void
    private let onRefresh: (() -> Void)?
    private let localConversations: [ConversationHistoryRecord]
    private let currentLocalID: UUID?
    private let canOpenLocal: Bool
    private let onOpenLocal: (ConversationHistoryRecord) -> Void

    @FocusState private var focusedControl: MarrWorkspaceSidebarFocus?
    @State private var actionError: String?
    @Binding private var showsUnassignedTasks: Bool
    @State private var pendingRenameTask: SavedTask?
    @State private var renameTaskID: UUID?
    @State private var renameDraft = ""
    @State private var showsRenameAlert = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    init(workspace: RuntimeWorkspaceController, searchText: Binding<String>,
         collapsedWorkspaceIDs: Binding<Set<UUID>>, expandedWorkspaceIDs: Binding<Set<UUID>>,
         isWorkActive: Bool = true, showsHeader: Bool = true, onSelectTask: @escaping () -> Void, onNewTask: @escaping () -> Void,
         onRefresh: (() -> Void)? = nil,
         localConversations: [ConversationHistoryRecord] = [], currentLocalID: UUID? = nil,
         conversationsExpanded: Binding<Bool> = .constant(true),
         canOpenLocal: Bool = true, onOpenLocal: @escaping (ConversationHistoryRecord) -> Void = { _ in }) {
        _showsUnassignedTasks = conversationsExpanded
        self.localConversations = localConversations
        self.currentLocalID = currentLocalID
        self.canOpenLocal = canOpenLocal
        self.onOpenLocal = onOpenLocal
        self.workspace = workspace
        self.workbench = workspace.workbench
        _searchText = searchText
        _collapsedWorkspaceIDs = collapsedWorkspaceIDs
        _expandedWorkspaceIDs = expandedWorkspaceIDs
        self.isWorkActive = isWorkActive
        self.showsHeader = showsHeader
        self.onSelectTask = onSelectTask
        self.onNewTask = onNewTask
        self.onRefresh = onRefresh
    }

    private var projects: [MarrWorkspaceSidebarContent.Project] {
        (workspace.codexSyncEnabled ? workspace.sidebarWorkspaces : []).compactMap {
            MarrWorkspaceSidebarContent.project($0, orderedTasks: workbench.orderedTasks(in: $0.id).filter { !workbench.isTaskPinned($0.id) },
                searchText: searchText, isCollapsed: collapsedWorkspaceIDs.contains($0.id),
                isExpanded: expandedWorkspaceIDs.contains($0.id), membershipResolved: true)
        }
    }

    private var isRefreshing: Bool { workspace.isLoadingTaskHistory || workspace.isLoadingProjects }
    private var blockReason: String? {
        if workspace.isRenamingTask { return "Wait for the conversation rename to finish." }
        if let reason = MarrWorkspaceSidebarContent.switchingBlockReason(isRunning: workspace.isRunning,
            isRemoteTaskActive: workspace.isRemoteTaskActive, isReading: workspace.isReadingSelectedTask,
            isUncertain: workspace.isTaskStatusUncertain, isReconciling: workspace.isReconcilingConnection,
            isRefreshing: isRefreshing) { return reason }
        // canSubmit also covers a queued thread read before the transport has
        // set isReadingSelectedTask, and command-thread preparation.
        return workspace.canSubmit ? nil : "Wait for pending conversation operations to finish."
    }
    private var selectedAccent: Color { MarrAccentColor.resolve(accentColor).color }
    private var refreshError: String? {
        ["thread/section/move", "thread/metadata/update", "project/list", "thread/list", "thread/name/set", "thread/archive", "thread/unarchive", "thread/fork"]
            .compactMap { workspace.capabilityErrors[$0] }.first
    }
    var body: some View {
        let projects = projects
        Group {
            if showsHeader { sectionHeader }
            let pinned = matchingTasks(workbench.pinnedSidebarTasks)
            if !pinned.isEmpty {
                Text("Pinned conversations").marrTextStyle(.caption).padding(.horizontal, 9)
                ForEach(pinned) { taskRow($0) }
            }
            if let error = actionError ?? refreshError {
                Label {
                    Text(verbatim: error).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    MarrIcon("exclamationmark.circle")
                }
                .marrTextStyle(.secondary)
                .foregroundStyle(MarrPanelColors.error(for: colorScheme))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .help(error)
                if refreshError != nil {
                    Button("Retry", action: refresh)
                        .buttonStyle(.borderless)
                        .disabled(isRefreshing || blockReason != nil)
                        .padding(.horizontal, 9)
                }
            }
            if pendingRenameTask != nil {
                Text("Loading conversation to rename…")
                    .marrTextStyle(.secondary)
                    .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
            }
            if workbench.desktopSidebarPreferences?.grouping == "list" {
                mixedConversations(matchingTasks(workbench.tasks.filter {
                    !workbench.isTaskPinned($0.id) && !workbench.isTaskArchived($0.id)
                }))
            } else if projects.isEmpty {
                if workbench.tasks.isEmpty && localConversations.isEmpty && workspace.codexSyncEnabled { emptyState }
            } else {
                ForEach([true, false], id: \.self) { pinned in
                    let group = projects.filter { $0.workspace.isPinned == pinned }
                    if !group.isEmpty {
                        if projects.contains(where: { $0.workspace.isPinned }) {
                            Text(pinned ? "Pinned workspaces" : "Other workspaces")
                                .marrTextStyle(.caption, weight: .medium)
                                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                                .padding(.horizontal, 9).padding(.top, 8)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group) { project in
                            Section {
                                if !project.isCollapsed {
                                    if project.tasks.isEmpty {
                                        Text("No conversations yet")
                                            .marrTextStyle(.secondary)
                                            .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                                            .padding(.leading, 30)
                                            .padding(.vertical, 6)
                                    }
                                    ForEach(project.visibleTasks) { task in
                                        taskRow(task)
                                            .id(task.id)
                                    }
                                    if !project.isSearching, project.tasks.count > 5 {
                                        Button(project.isExpanded ? "Show less" : "Show \(project.remainingCount) more") {
                                            animate {
                                                if project.isExpanded { expandedWorkspaceIDs.remove(project.id) }
                                                else { expandedWorkspaceIDs.insert(project.id) }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .marrTextStyle(.secondary)
                                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                        .padding(.leading, 30)
                                        .accessibilityLabel(project.isExpanded
                                            ? "Show fewer conversations in \(project.workspace.name)"
                                            : "Show \(project.remainingCount) more conversations in \(project.workspace.name)")
                                    }
                                }
                            } header: {
                                projectHeader(project)
                            }
                        }
                    }
                }
            }
            if workbench.desktopSidebarPreferences?.grouping != "list" {
                let unassigned = matchingTasks(workbench.tasks.filter { workbench.sidebarWorkspaceID(for: $0) == nil
                    && !workbench.isTaskPinned($0.id) && !workbench.isTaskArchived($0.id) })
                mixedConversations(unassigned)
            }

        }
        .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
        .onChange(of: workspace.canSubmit) { _, _ in presentPendingRenameIfReady() }
        .onChange(of: workspace.canRenameSelectedTask) { _, _ in presentPendingRenameIfReady() }
        .onChange(of: workspace.isReadingSelectedTask) { _, _ in presentPendingRenameIfReady() }
        .onChange(of: workspace.isRemoteTaskActive) { _, _ in presentPendingRenameIfReady() }
        .onChange(of: workspace.capabilityErrors["thread/read"]) { _, error in
            if pendingRenameTask != nil, let error {
                actionError = error
                pendingRenameTask = nil
            }
        }
        .onChange(of: workbench.selectedTaskID) { _, selected in
            if let pending = pendingRenameTask, selected != pending.id { pendingRenameTask = nil }
            if showsRenameAlert, selected != renameTaskID {
                showsRenameAlert = false
                renameTaskID = nil
            }
        }
        .alert("Rename conversation", isPresented: $showsRenameAlert) {
            TextField("Conversation name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTaskID = nil }
            Button("Save") { commitRename() }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blockReason != nil)
        } message: {
            Text("Choose a name for this conversation.")
        }
    }

    private func matchingTasks(_ tasks: [SavedTask]) -> [SavedTask] {
        guard workspace.codexSyncEnabled else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? tasks : tasks.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func mixedConversations(_ tasks: [SavedTask]) -> some View {
        let rows = MarrMixedConversationContent.rows(local: localConversations, codex: tasks, query: searchText)
        return Group {
            if !rows.isEmpty {
                Button { animate { showsUnassignedTasks.toggle() } } label: {
                    Label("Conversations · \(rows.count)", marrSymbol: showsUnassignedTasks ? "chevron.down" : "chevron.right")
                        .marrTextStyle(.caption).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                }.buttonStyle(.plain).padding(.horizontal, 9)
                if showsUnassignedTasks || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(rows) { row in
                        switch row {
                        case .local(let record): localRow(record).id(record.id)
                        case .codex(let task): taskRow(task).id(task.id)
                        }
                    }
                }
            }
        }
    }

    private func localRow(_ record: ConversationHistoryRecord) -> some View {
        let selected = !isWorkActive && currentLocalID == record.id
        return MarrHoverRegion { hovered in
            Button { onOpenLocal(record) } label: {
                MarrConversationRowLabel(title: AnswerPanelConversationTitle.make(from: record.title),
                    source: "Local", isSelected: selected)
                    .padding(.trailing, MarrUI.Control.compact + 6)
            }
            .buttonStyle(.plain)
            .disabled(!canOpenLocal)
            .background(rowBackground(selected: selected, hovered: hovered))
            .overlay(rowFocusBorder(selected: selected))
            .padding(.leading, 20)
            .help("\(record.title)\nLocal · \(MarrHistorySidebarContent.summary(for: record))")
            .accessibilityLabel(record.title)
            .accessibilityValue("Local")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("history-conversation-\(record.id.uuidString)")
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: MarrUI.Spacing.tight) {
            Text("Workspaces")
                .marrTextStyle(.caption, weight: .medium)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: addWorkspace) {
                MarrIcon("folder.badge.plus").frame(width: 28, height: 28)
            }
            .buttonStyle(MarrButtonStyle(.ghost, size: .icon, foregroundColor: MarrPanelColors.secondary(for: colorScheme)))
            .disabled(blockReason != nil)
            .help(blockReason ?? "Add a workspace folder")
            .accessibilityLabel("Add workspace")
        }
        .padding(.leading, 9)
        .padding(.trailing, 2)
    }

    private var emptyState: some View {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            Text(isSearching
                ? "No matching workspaces or conversations"
                : "No workspaces yet")
                .marrTextStyle(.secondary, weight: .medium)
            if !isSearching {
                Text("Add a folder to start a project conversation.")
                    .marrTextStyle(.secondary)
                    .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func projectHeader(_ project: MarrWorkspaceSidebarContent.Project) -> some View {
        let selected = isWorkActive && workbench.selectedWorkspaceID == project.id
        return MarrHoverRegion { hovered in
            let showsTools = hovered || focusedControl == .project(project.id)
                || focusedControl == .projectMenu(project.id) || focusedControl == .projectNew(project.id)
            HStack(spacing: 1) {
                Button {
                    animate {
                        if project.isCollapsed { collapsedWorkspaceIDs.remove(project.id) }
                        else { collapsedWorkspaceIDs.insert(project.id) }
                    }
                } label: {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        MarrIcon("chevron.right", size: MarrUI.Icon.disclosure)
                            .rotationEffect(.degrees(project.isCollapsed ? 0 : 90))
                            .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                            .frame(width: 9)
                        MarrIcon("folder", size: MarrUI.Icon.navigation)
                            .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                            .frame(width: 17)
                        Text(verbatim: project.workspace.name)
                            .marrTextStyle(.body, weight: selected ? .medium : .regular)
                            .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                            .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    }
                    .padding(.leading, 7)
                    .frame(maxWidth: .infinity, minHeight: MarrUI.Row.height, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(project.isSearching)
                .focused($focusedControl, equals: .project(project.id))
                .help(project.workspace.path)
                .accessibilityIdentifier("marr.workspace.toggle.\(project.id.uuidString)")
                .accessibilityLabel("\(project.workspace.name), \(project.workspace.path)")
                .accessibilityValue("\(project.isCollapsed ? "Collapsed" : "Expanded"), \(project.tasks.count) conversations")
                .accessibilityHint(project.isSearching ? "Search results are expanded" : "Expand or collapse conversations")
                .accessibilityAddTraits(selected ? .isSelected : [])
                Menu { projectActions(project.workspace) } label: {
                    MarrIcon("ellipsis.circle.fill", size: MarrUI.Icon.inline)
                        .frame(width: MarrUI.Control.compact, height: MarrUI.Control.compact)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .focused($focusedControl, equals: .projectMenu(project.id))
                .accessibilityLabel("Actions for \(project.workspace.name)")
                .opacity(showsTools ? 1 : 0)
                .accessibilityHidden(false)
                Button { newTask(in: project.workspace) } label: {
                    MarrIcon("square.and.pencil", size: MarrUI.Icon.inline)
                        .frame(width: MarrUI.Control.compact, height: MarrUI.Control.compact)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                        .opacity(showsTools ? 1 : 0)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .focused($focusedControl, equals: .projectNew(project.id))
                .disabled(blockReason != nil)
                .help(blockReason ?? "New conversation in \(project.workspace.name)")
                .accessibilityLabel("New conversation in \(project.workspace.name)")
            }
            .background(rowBackground(selected: selected, hovered: hovered))
            .overlay(rowFocusBorder(selected: selected))
            .contextMenu { projectActions(project.workspace) }
            .accessibilityIdentifier("marr.workspace.\(project.id.uuidString)")
        }
    }

    private func taskRow(_ task: SavedTask) -> some View {
        let isCurrentTask = workbench.selectedTaskID == task.id
        let isSelected = isWorkActive && isCurrentTask
        // Hover changes only row chrome. Building the project menus inside the
        // hover closure used to traverse the entire catalog on every hover tick.
        let actions = taskActions(task)
        return MarrHoverRegion { hovered in
            let showsTools = hovered || focusedControl == .task(task.id) || focusedControl == .taskMenu(task.id)
            let needsInput = task.threadID.map { thread in workspace.pendingInteractions.contains { $0.threadID == thread } } ?? false
            let status = MarrWorkspaceSidebarContent.status(savedState: task.state, isSelected: isCurrentTask,
                isRunning: workspace.isRunning, isRemoteTaskActive: workspace.isRemoteTaskActive,
                isReading: workspace.isReadingSelectedTask, isUncertain: workspace.isTaskStatusUncertain,
                isReconciling: workspace.isReconcilingConnection, needsInput: needsInput)
            HStack(spacing: 1) {
                MarrWorkspaceTaskRow(task: task, isSelected: isSelected, isPinned: workbench.isTaskPinned(task.id),
                    status: status, accent: selectedAccent, disabledReason: isCurrentTask ? nil : workspace.historySelectionBlockReason,
                    focus: $focusedControl) {
                        select(task)
                    }
                    .equatable()
                Menu { actions } label: {
                    MarrIcon("ellipsis.circle.fill", size: MarrUI.Icon.inline)
                        .frame(width: MarrUI.Control.compact, height: MarrUI.Control.compact)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                .focused($focusedControl, equals: .taskMenu(task.id))
                .accessibilityLabel("Actions for \(task.title)")
                .opacity(showsTools ? 1 : 0)
                .accessibilityHidden(false)
                .padding(.trailing, 5)
            }
            .background(rowBackground(selected: isSelected, hovered: hovered))
            .overlay(rowFocusBorder(selected: isSelected))
            .padding(.leading, 20)
            .contextMenu { actions }
        }
    }

    private func rowBackground(selected: Bool, hovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
            .fill(Color(white: colorScheme == .dark ? 1 : 0)
                .opacity(selected ? (colorScheme == .dark ? 0.10 : 0.065) : hovered ? 0.035 : 0))
    }

    private func rowFocusBorder(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
            .strokeBorder(MarrPanelColors.secondary(for: colorScheme)
                .opacity(selected && contrast == .increased ? 0.7 : 0), lineWidth: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func taskActions(_ task: SavedTask) -> some View {
        Button(workbench.isTaskPinned(task.id) ? "Unpin conversation" : "Pin conversation", marrSymbol: "pin") {
            guard blockReason == nil else { return }
            workspace.toggleTaskPinned(task)
        }
        .disabled(blockReason != nil || task.threadID.map { workspace.sidebarMutationThreadIDs.contains($0) } == true)
        if task.threadID != nil {
            Menu("Move to project") {
                Button("No project") { workspace.assignTask(task, to: nil) }
                ForEach(workspace.sidebarWorkspaces.filter { $0.projectID != nil }) { project in
                    Button(project.name) { workspace.assignTask(task, to: project) }
                }
            }
            .disabled(blockReason != nil || task.threadID.map { workspace.sidebarMutationThreadIDs.contains($0) } == true)
        }
        Button("Rename…", marrSymbol: "pencil") { beginRename(task) }
            .disabled(blockReason != nil || task.state == .running)
        Button("Move up", marrSymbol: "arrow.up") { move(task, direction: .up) }
            .disabled(blockReason != nil || (workbench.desktopSidebarPreferences != nil || workbench.supportsSharedSections) || !workbench.canMoveTask(task.id, direction: .up))
        Button("Move down", marrSymbol: "arrow.down") { move(task, direction: .down) }
            .disabled(blockReason != nil || (workbench.desktopSidebarPreferences != nil || workbench.supportsSharedSections) || !workbench.canMoveTask(task.id, direction: .down))
        if let threadID = task.threadID {
            Button("Copy thread ID", marrSymbol: "doc.on.doc") { copyThreadID(threadID) }
        }
        Divider()
        Button("Archive conversation", marrSymbol: "archivebox") {
            guard blockReason == nil, workspace.canSubmit,
                  let current = workbench.tasks.first(where: { $0.id == task.id }), current.state != .running,
                  !workspace.archivingTaskIDs.contains(task.id) else { return }
            workspace.archiveTask(current)
        }
        .disabled(blockReason != nil || !workspace.canSubmit || task.state == .running || workspace.archivingTaskIDs.contains(task.id))
        if workbench.selectedTaskID == task.id {
            Button("Fork conversation", marrSymbol: "arrow.triangle.branch") {
                guard blockReason == nil, workspace.canForkSelectedTask else { return }
                workspace.forkSelectedTask()
                onSelectTask()
            }
            .disabled(blockReason != nil || !workspace.canForkSelectedTask)
        }
    }

    @ViewBuilder
    private func projectActions(_ project: SavedWorkspace) -> some View {
        Button("New conversation", marrSymbol: "square.and.pencil") { newTask(in: project) }
            .disabled(blockReason != nil)
        Button("Refresh", marrSymbol: "arrow.clockwise") {
            guard blockReason == nil else { return }
            workspace.loadTaskHistory(for: project)
        }
        .disabled(blockReason != nil)
        Button(project.isPinned ? "Unpin workspace" : "Pin workspace", marrSymbol: "pin") {
            workspace.toggleWorkspacePinned(project)
        }
        .help("Pin or unpin this workspace in Marr")
        if project.pinOverride != nil, project.projectID != nil, workbench.desktopSidebarPreferences != nil {
            Button("Use Codex pin setting") { workspace.followDesktopWorkspacePin(project) }
        }
        Button("Show in Finder", marrSymbol: "folder") { workspace.showWorkspaceInFinder(project) }
        Divider()
        Button("Archive conversations", marrSymbol: "archivebox") {
            guard blockReason == nil, workspace.canSubmit,
                  !workbench.orderedTasks(in: project.id).contains(where: { $0.state == .running }) else { return }
            workspace.archiveChats(in: project)
        }
        .disabled(blockReason != nil || !workspace.canSubmit
                  || workbench.orderedTasks(in: project.id).contains { $0.state == .running })
        Button("Remove workspace", role: .destructive) {
            guard blockReason == nil else { return }
            workspace.removeWorkspace(project)
            collapsedWorkspaceIDs.remove(project.id)
            expandedWorkspaceIDs.remove(project.id)
        }
        .disabled(blockReason != nil)
    }

    private func beginRename(_ task: SavedTask) {
        guard blockReason == nil, let current = workbench.tasks.first(where: { $0.id == task.id }),
              current.state != .running, !workbench.isTaskArchived(current.id) else { return }
        actionError = nil
        pendingRenameTask = current
        if workbench.selectedTaskID != task.id { select(current) }
        guard workbench.selectedTaskID == task.id else { pendingRenameTask = nil; return }
        presentPendingRenameIfReady()
    }

    private func presentPendingRenameIfReady() {
        guard let task = pendingRenameTask else { return }
        if !workspace.isReadingSelectedTask,
           workspace.isRunning || workspace.isRemoteTaskActive || workspace.isTaskStatusUncertain || workspace.isReconcilingConnection {
            actionError = blockReason
            pendingRenameTask = nil
            return
        }
        guard MarrWorkspaceSidebarContent.canPresentRename(targetID: task.id, selectedID: workbench.selectedTaskID,
            canSubmit: workspace.canSubmit && blockReason == nil, canRename: workspace.canRenameSelectedTask,
            hasReadError: workspace.capabilityErrors["thread/read"] != nil) else { return }
        renameTaskID = task.id
        renameDraft = workbench.selectedTask?.title ?? task.title
        pendingRenameTask = nil
        showsRenameAlert = true
    }

    private func commitRename() {
        guard let target = renameTaskID, target == workbench.selectedTaskID, blockReason == nil,
              workspace.canSubmit, workspace.canRenameSelectedTask else {
            actionError = "The conversation changed or is busy. Open Rename again when it is ready."
            renameTaskID = nil
            return
        }
        if !workspace.renameSelectedTask(renameDraft) { actionError = workspace.commandOutput }
        renameTaskID = nil
    }

    private func move(_ task: SavedTask, direction: TaskMoveDirection) {
        guard workbench.desktopSidebarPreferences == nil, !workbench.supportsSharedSections, blockReason == nil, workbench.canMoveTask(task.id, direction: direction) else { return }
        animate { _ = workbench.moveTask(task.id, direction: direction) }
    }

    private func copyThreadID(_ threadID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(threadID, forType: .string)
    }

    private func select(_ task: SavedTask) {
        actionError = nil
        guard workspace.selectTask(task) else { actionError = workspace.statusMessage; return }
        onSelectTask()
    }

    private func newTask(in project: SavedWorkspace) {
        guard blockReason == nil else { return }
        actionError = nil
        guard workspace.selectWorkspace(project) else {
            actionError = workspace.statusMessage
            return
        }
        collapsedWorkspaceIDs.remove(project.id)
        onNewTask()
    }

    private func addWorkspace() {
        guard blockReason == nil else { return }
        let previousStatus = workspace.statusMessage
        // This is the only folder-picker entry point; never call it on appear,
        // refresh, an empty-state transition, or a failed access attempt.
        if workspace.chooseWorkspace() {
            actionError = nil
            onNewTask()
        } else if workspace.statusMessage != previousStatus {
            actionError = workspace.statusMessage
        }
    }

    private func refresh() {
        guard blockReason == nil else { return }
        actionError = nil
        if let onRefresh { onRefresh() } else { workspace.loadAllTaskHistory() }
    }

    private func animate(_ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16), changes)
    }
}

private struct MarrWorkspaceTaskRow: View, Equatable {
    let task: SavedTask
    let isSelected: Bool
    let isPinned: Bool
    let status: MarrWorkspaceSidebarContent.TaskStatus
    let accent: Color
    let disabledReason: String?
    let focus: FocusState<MarrWorkspaceSidebarFocus?>.Binding
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.task == rhs.task && lhs.isSelected == rhs.isSelected && lhs.isPinned == rhs.isPinned
            && lhs.status == rhs.status && lhs.accent == rhs.accent && lhs.disabledReason == rhs.disabledReason
    }

    private var statusColor: Color {
        switch status {
        case .running: accent
        case .needsInput: .orange
        case .failed: MarrPanelColors.error(for: colorScheme)
        default: MarrPanelColors.secondary(for: colorScheme)
        }
    }

    var body: some View {
#if DEBUG
        let _ = MarrScrollDiagnostics.recordTaskEvaluation()
#endif
        Button(action: action) {
            MarrConversationRowLabel(title: task.title, source: "Codex", isSelected: isSelected,
                statusSymbol: status.symbol, statusColor: statusColor, statusTitle: status.title)

        }
        .buttonStyle(.plain)
        .focused(focus, equals: .task(task.id))
        .disabled(disabledReason != nil)
        .opacity(disabledReason == nil ? 1 : 0.65)
        .help(disabledReason ?? "\(task.title)\n\(status.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(task.title)
        .accessibilityValue("Codex, " + (isPinned ? "Pinned, " : "") + status.title)
        .accessibilityHint(disabledReason ?? "Open conversation")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("marr.workspace.task.\(task.id.uuidString)")
    }
}

/// Shared visual language; the source only affects the badge and opening action.
private struct MarrConversationRowLabel: View {
    let title: String
    let source: String
    let isSelected: Bool
    var statusSymbol: String? = nil
    var statusColor: Color = .secondary
    var statusTitle = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            MarrIcon(isSelected ? "bubble.left.fill" : "bubble.left", size: MarrUI.Icon.inline)
                .foregroundStyle(isSelected ? MarrPanelColors.primary(for: colorScheme) : MarrPanelColors.secondary(for: colorScheme))
                .frame(width: 15)
            MarrScrollingConversationTitle(title: title, isSelected: isSelected)
                .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
            Text(source).marrTextStyle(.badge, weight: .medium)
                .foregroundStyle(source == "Codex" ? Color.accentColor : MarrPanelColors.secondary(for: colorScheme))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background((source == "Codex" ? Color.accentColor : Color.primary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder((source == "Codex" ? Color.accentColor : Color.primary).opacity(0.16), lineWidth: 0.5))
                .fixedSize()
            if let statusSymbol {
                MarrIcon(statusSymbol, size: MarrUI.Icon.status)
                    .foregroundStyle(statusColor).help(statusTitle)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: MarrUI.Row.height)
        .contentShape(RoundedRectangle(cornerRadius: MarrUI.Radius.control))
    }
}

enum MarrMixedConversationContent {
    enum Row: Identifiable {
        case local(ConversationHistoryRecord), codex(SavedTask)
        var id: String {
            switch self {
            case .local(let record): "local-" + record.id.uuidString
            case .codex(let task): "codex-" + task.id.uuidString
            }
        }
        var updatedAt: Date {
            switch self {
            case .local(let record): record.updatedAt
            case .codex(let task): task.updatedAt
            }
        }
    }

    static func rows(local: [ConversationHistoryRecord], codex: [SavedTask], query: String) -> [Row] {
        let records = local.filter { !$0.isArchived && $0.workspaceID == nil
            && MarrGlobalSearchContent.matches($0, query: query) }
        return (records.map(Row.local) + codex.map(Row.codex)).sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}

/// The timer only exists while an overflowing title is hovered. Short titles and
/// reduced-motion users retain normal truncation and the full-title tooltip.
struct MarrScrollingConversationTitle: View {
    let title: String
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverStartedAt: Date?
    @State private var textWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private var label: some View {
        Text(verbatim: title).marrTextStyle(.body, weight: isSelected ? .medium : .regular)
    }

    var body: some View {
        let overflow = max(0, textWidth - viewportWidth)
        let scrolls = hoverStartedAt != nil && overflow > 1 && !reduceMotion
        label.lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .opacity(scrolls ? 0 : 1)
            .background(alignment: .leading) {
                label.fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls, let start = hoverStartedAt {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        label.fixedSize()
                            .offset(x: MarrTitleMarquee.offset(elapsed: context.date.timeIntervalSince(start), overflow: overflow))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onHover { hoverStartedAt = $0 ? Date() : nil }
            .onChange(of: title) { _, _ in hoverStartedAt = nil }
            .onDisappear { hoverStartedAt = nil }
            .help(title)
    }
}

enum MarrTitleMarquee {
    static func offset(elapsed: TimeInterval, overflow: CGFloat) -> CGFloat {
        guard overflow > 1, elapsed > 0.7 else { return 0 }
        let duration = Double(overflow) / 28
        let pause = 0.8
        let phase = (elapsed - 0.7).truncatingRemainder(dividingBy: 2 * (duration + pause))
        if phase < duration { return -CGFloat(phase / duration) * overflow }
        if phase < duration + pause { return -overflow }
        if phase < 2 * duration + pause { return -overflow * CGFloat(1 - (phase - duration - pause) / duration) }
        return 0
    }
}
