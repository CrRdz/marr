import AppKit
import MarrCore
import SwiftUI

/// Reports Marr-owned data only. Linked project folders and Codex's external
/// storage are not included in this total and are never deleted by this view.
struct MarrStorageSettingsView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var history: ConversationHistoryStore
    @State private var destination: StorageDestination?

    init(controller: MarrController) {
        self.controller = controller
        self.history = controller.historyStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.section) {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                HStack(spacing: 5) {
                    Text("This device").marrTextStyle(.title, weight: .semibold)
                        .accessibilityAddTraits(.isHeader)
                    MarrSettingsInfo(title: "Local storage", message: "Includes Marr chats and attachments. Linked folders and Codex storage are managed separately.")
                }
            }

            VStack(alignment: .leading, spacing: MarrUI.Spacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text(history.storageReport.map { "Marr uses \(Self.byteCount($0.totalBytes))" } ?? "Calculating storage…")
                        .marrTextStyle(.body, weight: .semibold)
                    Spacer(minLength: 8)
                    if history.isLoadingStorage { ProgressView().controlSize(.small) }
                    Button("Refresh") { history.refreshStorage() }
                        .disabled(history.isLoadingStorage)
                }
                if let report = history.storageReport {
                    storageBar(report)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)], alignment: .leading, spacing: 12) {
                        ForEach(report.categories) { category in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Circle().fill(color(for: category)).frame(width: 8, height: 8)
                                        .accessibilityHidden(true)
                                    Text(category.title).marrTextStyle(.secondary)
                                }
                                Text(Self.byteCount(category.bytes))
                                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text("\(report.conversationCount) chats · \(report.archivedConversationCount) archived · \(report.workspaceCount) workspaces")
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    if !report.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Some storage could not be measured.").fontWeight(.medium)
                            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(history.rootURL.path)
                        .marrTextStyle(.secondary).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: history.rootURL.path)
                    }
                    .controlSize(.small)
                }
            }

            VStack(spacing: 0) {
                managementRow("Review chats", subtitle: "Review saved conversations before archiving or deleting them.", action: "Review") {
                    destination = .chats
                }
                Divider().padding(.horizontal, 14)
                managementRow("Archived chats", subtitle: "Restore a local chat or delete it permanently.", action: "Manage") {
                    destination = .archives
                }
                Divider().padding(.horizontal, 14)
                managementRow("Workspaces", subtitle: "Manage workspace names and linked folders.", action: "Manage") {
                    destination = .workspaces
                }
            }
            .marrSurface(.card, cornerRadius: MarrUI.Radius.panel)
            if let error = history.lastErrorMessage {
                Text(error).marrTextStyle(.secondary).foregroundStyle(MarrUI.Status.error.color())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { history.refreshStorage() }
        .sheet(item: $destination) { destination in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(destination.title).marrTextStyle(.pageTitle, weight: .semibold)
                    Spacer()
                    Button("Done") { self.destination = nil }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    if destination == .workspaces {
                        MarrWorkspaceStorageView(controller: controller)
                    } else {
                        MarrLocalChatStorageView(controller: controller, archivedOnly: destination == .archives)
                    }
                }
            }
            .padding(24)
            .frame(minWidth: 460, idealWidth: 560, maxWidth: 700, minHeight: 360, idealHeight: 520, maxHeight: 700)
        }
    }

    private func storageBar(_ report: LocalStorageReport) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if report.totalBytes > 0 {
                    ForEach(report.categories.filter { $0.bytes > 0 }) { category in
                        Rectangle().fill(color(for: category))
                            .frame(width: geometry.size.width * CGFloat(category.bytes) / CGFloat(report.totalBytes))
                    }
                } else {
                    Rectangle().fill(.secondary.opacity(0.15))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage breakdown")
        .accessibilityValue(report.categories.map { "\($0.title): \(Self.byteCount($0.bytes))" }.joined(separator: ", "))
    }

    private func color(for category: LocalStorageCategory) -> Color {
        switch category.kind {
        case .database: .yellow
        case .attachments: .blue
        case .archivedAttachments: .orange
        case .workspaceData: .green
        case .other: .gray
        }
    }

    private func managementRow(_ title: String, subtitle: String, action: String, perform: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                rowText(title, subtitle: subtitle)
                Spacer(minLength: 12)
                Button(action, action: perform).controlSize(.regular)
            }
            VStack(alignment: .leading, spacing: 12) {
                rowText(title, subtitle: subtitle)
                Button(action, action: perform).controlSize(.regular)
            }
        }
        .padding(14)
    }

    private func rowText(_ title: String, subtitle: String) -> some View {
        HStack(spacing: 5) {
            Text(title).marrTextStyle(.body, weight: .medium)
            MarrSettingsInfo(title: title, message: subtitle)
        }
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private enum StorageDestination: String, Identifiable {
        case chats, archives, workspaces
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chats: "Local chats"
            case .archives: "Archived local chats"
            case .workspaces: "Local workspaces"
            }
        }
    }
}

struct MarrLocalChatStorageView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var history: ConversationHistoryStore
    let archivedOnly: Bool
    @State private var query = ""
    @State private var pendingDeletion: ConversationHistoryRecord?
    @State private var busyIDs: Set<UUID> = []

    init(controller: MarrController, archivedOnly: Bool) {
        self.controller = controller
        self.history = controller.historyStore
        self.archivedOnly = archivedOnly
    }

    private var records: [ConversationHistoryRecord] {
        history.conversations.filter {
            $0.isArchived == archivedOnly && (query.isEmpty || $0.title.localizedStandardContains(query)
                || workspaceName($0).localizedStandardContains(query))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(archivedOnly ? "Search archived local chats" : "Search local chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(archivedOnly ? "Search archived local chats" : "Search local chats")
            HStack {
                Text("\(records.count) chats").marrTextStyle(.secondary).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { history.reload() }
            }
            if controller.activeInferenceRequests > 0 {
                Text("Storage changes are available after the active request finishes.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = history.lastErrorMessage {
                Text(error).marrTextStyle(.secondary).foregroundStyle(MarrUI.Status.error.color())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if records.isEmpty {
                Text(query.isEmpty ? (archivedOnly ? "No archived local chats." : "No local chats yet.") : "No chats match your search.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            LazyVStack(spacing: 0) {
                ForEach(records) { record in
                    chatRow(record)
                    if record.id != records.last?.id { Divider() }
                }
            }
        }
        .onAppear { history.reload() }
        .alert("Delete chat permanently?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { record in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                mutate(record.id) { history.delete(record.id) }
            }
        } message: { record in
            Text("“\(record.title)” and its saved attachments will be removed from this Mac. This cannot be undone.")
        }
    }

    private func chatRow(_ record: ConversationHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.title).marrTextStyle(.body, weight: .medium).lineLimit(2)
            HStack(spacing: 8) {
                Text(workspaceName(record)).lineLimit(1).truncationMode(.middle)
                Text(record.updatedAt, format: .dateTime.year().month().day())
            }
            .marrTextStyle(.secondary).foregroundStyle(.secondary)
            HStack {
                Button("View") { controller.openHistoryConversation(record) }
                    .disabled(controller.activeInferenceRequests > 0)
                Button(archivedOnly ? "Restore" : "Archive") {
                    mutate(record.id) { history.setArchived(record.id, archived: !archivedOnly) }
                }
                Button("Delete…", role: .destructive) { pendingDeletion = record }
                Spacer()
                if busyIDs.contains(record.id) { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            .disabled(busyIDs.contains(record.id) || controller.activeInferenceRequests > 0)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func workspaceName(_ record: ConversationHistoryRecord) -> String {
        guard let id = record.workspaceID else { return "Conversation" }
        return history.workspaces.first { $0.id == id }?.name ?? "Local workspace"
    }

    private func mutate(_ id: UUID, operation: () -> Void) {
        guard controller.activeInferenceRequests == 0, !busyIDs.contains(id) else { return }
        busyIDs.insert(id)
        operation()
        Task {
            await history.waitForPendingOperations()
            busyIDs.remove(id)
            history.refreshStorage()
        }
    }
}

private struct MarrWorkspaceStorageView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var history: ConversationHistoryStore
    @State private var pendingRemoval: LocalWorkspaceRecord?

    init(controller: MarrController) {
        self.controller = controller
        self.history = controller.historyStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Text("Workspaces").marrTextStyle(.body, weight: .semibold)
                MarrSettingsInfo(title: "Workspaces", message: "Removing a workspace keeps its chats and leaves the linked folder untouched.")
            }
            if history.workspaces.isEmpty {
                Text("No local workspaces yet. Create one from the sidebar.")
                    .marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            if let error = history.lastErrorMessage {
                Text(error).marrTextStyle(.secondary).foregroundStyle(MarrUI.Status.error.color())
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(spacing: 0) {
                ForEach(history.workspaces) { workspace in
                    MarrStoredWorkspaceRow(workspace: workspace,
                        chatCount: history.conversations.filter { $0.workspaceID == workspace.id }.count,
                        disabled: controller.activeInferenceRequests > 0,
                        rename: { history.renameWorkspace(workspace.id, name: $0) },
                        remove: { pendingRemoval = workspace })
                    if workspace.id != history.workspaces.last?.id { Divider() }
                }
            }
        }
        .alert("Remove workspace?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { workspace in
            Button("Cancel", role: .cancel) {}
            Button("Remove workspace", role: .destructive) {
                guard controller.activeInferenceRequests == 0 else { return }
                history.removeWorkspace(workspace.id)
                Task {
                    await history.waitForPendingOperations()
                    history.refreshStorage()
                }
            }
        } message: { workspace in
            Text("“\(workspace.name)” will be removed from Marr. Its chats will remain in Conversation. Files in its linked folder will not be deleted.")
        }
    }
}

private struct MarrStoredWorkspaceRow: View {
    let workspace: LocalWorkspaceRecord
    let chatCount: Int
    let disabled: Bool
    let rename: (String) -> Void
    let remove: () -> Void
    @State private var draftName: String

    init(workspace: LocalWorkspaceRecord, chatCount: Int, disabled: Bool,
         rename: @escaping (String) -> Void, remove: @escaping () -> Void) {
        self.workspace = workspace; self.chatCount = chatCount; self.disabled = disabled
        self.rename = rename; self.remove = remove
        _draftName = State(initialValue: workspace.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Workspace name", text: $draftName).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name of \(workspace.name)")
                Button("Save") { rename(draftName.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftName == workspace.name)
            }
            .disabled(disabled)
            if let path = workspace.path, !path.isEmpty {
                Text(path).marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(chatCount) chats").marrTextStyle(.secondary).foregroundStyle(.secondary)
                Spacer()
                Button("Remove…", role: .destructive, action: remove).disabled(disabled)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 12)
        .onChange(of: workspace.name) { _, name in draftName = name }
    }
}
