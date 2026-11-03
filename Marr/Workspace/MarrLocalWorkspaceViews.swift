import AppKit
import MarrCore
import SwiftUI

/// Marr-owned workspace navigation. Codex projects are presented separately only after opt-in.
struct MarrLocalWorkspaceSidebar: View {
    @ObservedObject var store: ConversationHistoryStore
    let currentConversationID: UUID?
    let currentWorkspaceID: UUID?
    let searchText: String
    var showsHeader = true
    let canChangeConversation: Bool
    let onNewWorkspace: () -> Void
    let onNewConversation: (LocalWorkspaceRecord) -> Void
    let onOpen: (ConversationHistoryRecord) -> Void
    @State private var collapsed: Set<UUID> = []
    @State private var expanded: Set<UUID> = []
    @Environment(\.colorScheme) private var colorScheme

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var workspaces: [LocalWorkspaceRecord] {
        store.workspaces.filter { workspace in
            query.isEmpty || workspace.name.localizedCaseInsensitiveContains(query)
                || (workspace.path?.localizedCaseInsensitiveContains(query) == true)
                || conversations(in: workspace).contains(where: { matches($0) })
        }
    }

    var body: some View {
        if showsHeader {
        HStack {
            Text("Workspaces").marrTextStyle(.caption, weight: .medium)
            Spacer()
            Button(action: onNewWorkspace) { MarrIcon("plus", size: MarrUI.Icon.inline).frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("New workspace").accessibilityLabel("New workspace")
                .disabled(!canChangeConversation)
        }
        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
        .padding(.leading, 9)
        }
        if showsHeader && workspaces.isEmpty {
            Text(query.isEmpty ? "Create a workspace to organize your chats." : "No matching workspaces")
                .marrTextStyle(.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9).padding(.vertical, 8)
        }
        ForEach(workspaces) { workspace in
            let chats = conversations(in: workspace).filter {
                query.isEmpty || workspace.name.localizedCaseInsensitiveContains(query)
                    || workspace.path?.localizedCaseInsensitiveContains(query) == true || matches($0)
            }
            let isExpanded = !query.isEmpty || !collapsed.contains(workspace.id)
            HStack(spacing: 4) {
                Button {
                    if collapsed.contains(workspace.id) { collapsed.remove(workspace.id) }
                    else { collapsed.insert(workspace.id) }
                } label: {
                    HStack(spacing: 6) {
                        MarrIcon("chevron.right", size: MarrUI.Icon.disclosure).rotationEffect(.degrees(isExpanded ? 90 : 0))
                        MarrIcon("folder", size: MarrUI.Icon.inline)
                        Text(workspace.name).marrTextStyle(.body, weight: currentWorkspaceID == workspace.id ? .medium : .regular).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                Button { onNewConversation(workspace) } label: {
                    MarrIcon("square.and.pencil", size: MarrUI.Icon.inline).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).disabled(!canChangeConversation)
                .help("New chat in \(workspace.name)").accessibilityLabel("New chat in \(workspace.name)")
            }
            .frame(height: 32).padding(.leading, 9)
            .help(workspace.path ?? "Stored locally in Marr")
            if isExpanded {
                let visible = !query.isEmpty || expanded.contains(workspace.id) ? chats : Array(chats.prefix(5))
                ForEach(visible) { chat in
                    Button { onOpen(chat) } label: {
                        HStack {
                            Text(chat.title).marrTextStyle(.body, weight: chat.id == currentConversationID ? .medium : .regular)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 36).padding(.trailing, 9).frame(height: 32)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .background(chat.id == currentConversationID ? Color.primary.opacity(0.07) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).disabled(!canChangeConversation)
                    .help(chat.title)
                    .contextMenu {
                        Button("Archive") { store.setArchived(chat.id, archived: true) }.disabled(!canChangeConversation)
                        Menu("Move to workspace") {
                            Button("No workspace") { store.assignConversation(chat.id, to: nil) }
                            ForEach(store.workspaces.filter { $0.id != workspace.id }) { target in
                                Button(target.name) { store.assignConversation(chat.id, to: target.id) }
                            }
                        }.disabled(!canChangeConversation)
                    }
                }
                if chats.isEmpty {
                    Text("No chats yet").marrTextStyle(.secondary).foregroundStyle(.secondary)
                        .padding(.leading, 36).padding(.vertical, 5)
                } else if query.isEmpty && chats.count > 5 && !expanded.contains(workspace.id) {
                    Button("Show \(chats.count - 5) more") { expanded.insert(workspace.id) }
                        .buttonStyle(.plain).marrTextStyle(.secondary).foregroundStyle(.secondary)
                        .padding(.leading, 36).padding(.vertical, 5)
                }
            }
        }
    }

    private func conversations(in workspace: LocalWorkspaceRecord) -> [ConversationHistoryRecord] {
        store.conversations.filter { $0.workspaceID == workspace.id && !$0.isArchived }
    }
    private func matches(_ record: ConversationHistoryRecord) -> Bool {
        record.title.localizedCaseInsensitiveContains(query) || record.turns.contains { $0.question.localizedCaseInsensitiveContains(query) || $0.answer.localizedCaseInsensitiveContains(query) }
    }
}

struct MarrLocalWorkLanding<Composer: View>: View {
    @ObservedObject var store: ConversationHistoryStore
    @Environment(\.colorScheme) private var colorScheme
    var selectedWorkspace: LocalWorkspaceRecord? = nil
    var composerWidth: CGFloat? = nil
    var onNewWorkspace: () -> Void = {}
    let onSelect: (LocalWorkspaceRecord) -> Void
    @ViewBuilder let composer: () -> Composer

    var body: some View {
        MarrComposerLanding(isWork: true) {
            VStack(spacing: 0) {
                composer().zIndex(1)
                HStack(spacing: 12) {
                    Menu {
                        ForEach(store.workspaces) { workspace in
                            Button { onSelect(workspace) } label: {
                                if selectedWorkspace?.id == workspace.id {
                                    Label(workspace.name, systemImage: "checkmark")
                                } else { Text(workspace.name) }
                            }
                        }
                        if !store.workspaces.isEmpty { Divider() }
                        Button("New workspace…", action: onNewWorkspace)
                    } label: {
                        HStack(spacing: 8) {
                            MarrIcon("folder", size: MarrUI.Icon.navigation)
                            Text(selectedWorkspace?.name ?? "Project or folder")
                                .marrTextStyle(.body).lineLimit(1)
                            MarrIcon("chevron.down", size: MarrUI.Icon.disclosure)
                        }
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Project or folder")
                    .accessibilityValue(selectedWorkspace?.name ?? "No workspace selected")
                    Spacer(minLength: 8)
                    MarrIcon("info.circle", size: MarrUI.Icon.inline)
                        .foregroundStyle(MarrPanelColors.secondary(for: colorScheme))
                        .help("Choose a workspace to keep its conversations and project folder together.")
                        .accessibilityLabel("Workspaces group conversations and an optional project folder")
                }
                .foregroundStyle(MarrPanelColors.primary(for: colorScheme))
                .padding(.horizontal, 20)
                .frame(height: MarrChatLayout.workspaceFooterHeight)
                if let error = store.lastErrorMessage {
                    VStack(spacing: 8) {
                        Text(error).marrTextStyle(.secondary).foregroundStyle(.red).textSelection(.enabled)
                        Button("Reload") { store.reload() }
                    }.padding(12)
                }
            }
            .frame(width: composerWidth)
            .background {
                RoundedRectangle(cornerRadius: MarrUI.Radius.composer, style: .continuous)
                    .fill(.primary.opacity(0.025))
            }
            .overlay {
                // One continuous shell behind the inset composer and project
                // strip; the lower row must not introduce square upper corners.
                RoundedRectangle(cornerRadius: MarrUI.Radius.composer, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { store.reload() }
    }
}

struct MarrWorkspaceCreationSheet: View {
    @ObservedObject var store: ConversationHistoryStore
    let onCreated: (LocalWorkspaceRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?
    @State private var bookmark: Data?
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New workspace").marrTextStyle(.title, weight: .semibold)
            Text("Name a workspace for related chats. You can optionally associate a folder; existing files remain in place.")
                .marrTextStyle(.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Workspace name", text: $name).textFieldStyle(.roundedBorder)
                .focused($nameFocused).accessibilityLabel("Workspace name")
            HStack {
                Text(folder?.path ?? "No folder attached").marrTextStyle(.secondary).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose folder…", action: chooseFolder).disabled(isSaving)
                if folder != nil { Button("Remove") { folder = nil; bookmark = nil }.disabled(isSaving) }
            }
            if let error { Text(error).marrTextStyle(.secondary).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 460).onAppear { nameFocused = true }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            folder = url
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = url.lastPathComponent }
            error = nil
        } catch { self.error = "Could not save access to this folder: \(error.localizedDescription)" }
    }

    private func create() {
        isSaving = true; error = nil
        Task {
            do {
                let workspace = try await store.createWorkspace(name: name, path: folder?.path, bookmark: bookmark)
                dismiss()
                onCreated(workspace)
            } catch { self.error = error.localizedDescription; isSaving = false }
        }
    }
}
