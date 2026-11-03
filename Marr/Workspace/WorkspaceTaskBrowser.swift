import AppKit
import Combine
import MarrCore
import QuartzCore
import SwiftUI

struct WorkspaceTaskBrowser: View {
    @ObservedObject var workspace: RuntimeWorkspaceController
    @ObservedObject private var workbench: WorkbenchStore
    let onSelectTask: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var collapsedProjectIDs: Set<UUID> = []
    @State private var hoveredProjectID: UUID?
    @State private var showsArchivedTasks = false
    @State private var dropTargetID: UUID?

    private static let taskDragType = "com.marr.task-order"

    init(workspace: RuntimeWorkspaceController, onSelectTask: @escaping () -> Void) {
        self.workspace = workspace
        self.workbench = workspace.workbench
        self.onSelectTask = onSelectTask
    }

    private var canReorderTasks: Bool {
        workbench.desktopSidebarPreferences == nil && !workbench.supportsSharedSections && !workspace.isRunning && !workspace.isRemoteTaskActive
            && !workspace.isLoadingTaskHistory && !workspace.isLoadingProjects
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
                HStack {
                    Button(action: onSelectTask) {
                        MarrIcon("chevron.left")
                    }
                    .buttonStyle(.plain)
                    .help("Back to Work")
                    Text("Projects")
                        .font(MarrTypography.font(.pageTitle))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Button {
                        workspace.loadAllTaskHistory()
                    } label: {
                        MarrIcon("arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.isRunning || workspace.isLoadingTaskHistory || workspace.isLoadingProjects)
                    .help("Refresh projects")
                    .accessibilityLabel("Refresh projects")
                    Button {
                        if workspace.chooseWorkspace() {
                            onSelectTask()
                        }
                    } label: {
                        Label("New workspace", marrSymbol: "plus")
                            .font(MarrTypography.font(.secondary, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }

                if workspace.isLoadingTaskHistory || workspace.isLoadingProjects {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing…")
                            .font(MarrTypography.font(.secondary))
                            .foregroundStyle(.secondary)
                    }
                }

                if workspace.savedWorkspaces.isEmpty {
                    ContentUnavailableView {
                        Label("No projects", marrSymbol: "folder")
                    } description: {
                        Text("Add a project to start.")
                    }
                } else {
                    ForEach(workspace.savedWorkspaces) { project in
                        projectSection(project)
                    }
                }
                DisclosureGroup("Archived chats", isExpanded: $showsArchivedTasks) {
                    let archivedTasks = workspace.workbench.tasks.filter { workspace.workbench.isTaskArchived($0.id) }
                    if archivedTasks.isEmpty {
                        Text("No archived chats in this workbench.")
                            .font(MarrTypography.font(.secondary)).foregroundStyle(.secondary)
                    }
                    ForEach(archivedTasks) { task in
                        HStack {
                            Text(task.title).lineLimit(1)
                            Spacer()
                            Button("Restore") { workspace.unarchiveTask(task) }
                                .controlSize(.small)
                                .disabled(workspace.isRunning)
                        }
                        .font(MarrTypography.font(.secondary))
                        .padding(.vertical, 4)
                    }
                }
                .font(MarrTypography.font(.secondary))
            }
            .padding(.top, 0)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
    }

    private func projectSection(_ project: SavedWorkspace) -> some View {
        let tasks = workbench.orderedTasks(in: project.id)
        let isCollapsed = collapsedProjectIDs.contains(project.id)
        let isExpanded = expandedProjectIDs.contains(project.id)
        let visibleTasks = isExpanded ? tasks : Array(tasks.prefix(5))
        return VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
            HStack(spacing: MarrUI.Spacing.regular) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if isCollapsed {
                            collapsedProjectIDs.remove(project.id)
                        } else {
                            collapsedProjectIDs.insert(project.id)
                        }
                    }
                } label: {
                    HStack(spacing: MarrUI.Spacing.regular) {
                        MarrIcon("folder", size: MarrUI.Icon.inline)
                        Text(project.name)
                            .font(MarrTypography.font(.body, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: MarrUI.Spacing.tight) {
                    Menu {
                        Button("Refresh", marrSymbol: "arrow.clockwise") {
                            workspace.loadTaskHistory(for: project)
                        }
                        .disabled(workspace.isRunning || workspace.isLoadingTaskHistory)
                        Button(project.isPinned ? "Unpin project" : "Pin project") {
                            workspace.toggleWorkspacePinned(project)
                        }
                        .help("Pin or unpin this workspace in Marr")
                        if project.pinOverride != nil, project.projectID != nil, workbench.desktopSidebarPreferences != nil {
                            Button("Use Codex pin setting") { workspace.followDesktopWorkspacePin(project) }
                        }
                        Button("Show in Finder") {
                            workspace.showWorkspaceInFinder(project)
                        }
                        Button("Archive chats") {
                            workspace.archiveChats(in: project)
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            workspace.removeWorkspace(project)
                        }
                    } label: {
                        MarrIcon("ellipsis")
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Actions for \(project.name)")

                    Button {
                        workspace.selectWorkspace(project)
                        onSelectTask()
                    } label: {
                        MarrIcon("square.and.pencil")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(workspace.isRunning)
                    .help("New chat in \(project.name)")
                    .accessibilityLabel("New chat in \(project.name)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                hoveredProjectID == project.id ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .onHover { isHovered in
                hoveredProjectID = isHovered ? project.id : nil
            }

            if !isCollapsed, tasks.isEmpty {
                Text("No chats")
                    .font(MarrTypography.font(.secondary))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            } else if !isCollapsed {
                ForEach(visibleTasks) { task in
                    taskRow(task)
                }
                if tasks.count > 5 {
                    Button(isExpanded ? "Show less" : "Show \(tasks.count - 5) more") {
                        withAnimation(.easeOut(duration: 0.16)) {
                            if isExpanded {
                                expandedProjectIDs.remove(project.id)
                            } else {
                                expandedProjectIDs.insert(project.id)
                            }
                        }
                    }
                    .font(MarrTypography.font(.secondary, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func taskRow(_ task: SavedTask) -> some View {
        let isSelected = workspace.workbench.selectedTaskID == task.id
        return HStack(spacing: MarrUI.Spacing.tight) {
            Button {
                if workspace.selectTask(task) { onSelectTask() }
            } label: {
                HStack(spacing: MarrUI.Spacing.regular) {
                    if workspace.pinnedTaskIDs.contains(task.id) {
                        MarrIcon("pin.fill", size: MarrUI.Icon.disclosure).foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    Text(task.title)
                        .font(MarrTypography.font(.body, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if task.state == .running {
                        Circle()
                            .fill(.blue)
                            .frame(width: 9, height: 9)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Menu {
                taskActions(task)
            } label: {
                MarrIcon("ellipsis").frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Actions for \(task.title)")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(
            isSelected ? Color.primary.opacity(0.09) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            if canReorderTasks && dropTargetID == task.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, 26)
        .contextMenu { taskActions(task) }
        .onDrag {
            let provider = NSItemProvider()
            guard canReorderTasks, task.state != .running else { return provider }
            provider.registerDataRepresentation(forTypeIdentifier: Self.taskDragType, visibility: .ownProcess) { completion in
                completion(Data(task.id.uuidString.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [Self.taskDragType], isTargeted: Binding(
            get: { dropTargetID == task.id },
            set: { dropTargetID = $0 ? task.id : nil }
        )) { providers, location in
            guard canReorderTasks, task.state != .running, let provider = providers.first else { return false }
            let placement: TaskPlacement = location.y < 16 ? .before : .after
            provider.loadDataRepresentation(forTypeIdentifier: Self.taskDragType) { data, _ in
                guard let data, let value = String(data: data, encoding: .utf8),
                      let sourceID = UUID(uuidString: value) else { return }
                Task { @MainActor in
                    // Recheck after asynchronous payload loading: a turn may have
                    // started or a task moved projects while the user dragged.
                    guard canReorderTasks else { return }
                    withAnimation(MarrMotion.selection(reducesMotion: reducesMotion)) {
                        _ = workbench.moveTask(sourceID, relativeTo: task.id, placement: placement)
                    }
                }
            }
            dropTargetID = nil
            return true
        }
    }

    private func moveTask(_ task: SavedTask, direction: TaskMoveDirection) {
        guard canReorderTasks else { return }
        withAnimation(MarrMotion.selection(reducesMotion: reducesMotion)) {
            _ = workbench.moveTask(task.id, direction: direction)
        }
    }

    @ViewBuilder
    private func taskActions(_ task: SavedTask) -> some View {
        Button(workspace.pinnedTaskIDs.contains(task.id) ? "Unpin chat" : "Pin chat", marrSymbol: "pin") {
            workspace.toggleTaskPinned(task)
        }
        Button("Move up", marrSymbol: "arrow.up") { moveTask(task, direction: .up) }
            .disabled(!canReorderTasks || !workbench.canMoveTask(task.id, direction: .up))
        Button("Move down", marrSymbol: "arrow.down") { moveTask(task, direction: .down) }
            .disabled(!canReorderTasks || !workbench.canMoveTask(task.id, direction: .down))
        if let threadID = task.threadID {
            Button("Copy thread ID", marrSymbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(threadID, forType: .string)
            }
        }
        Divider()
        Button("Archive chat", marrSymbol: "archivebox") { workspace.archiveTask(task) }
            .disabled(!workspace.canSubmit || workspace.archivingTaskIDs.contains(task.id))
        if workbench.selectedTaskID == task.id {
            Button("Fork chat", marrSymbol: "arrow.triangle.branch") { workspace.forkSelectedTask() }
                .disabled(!workspace.canForkSelectedTask)
        }
    }
}
