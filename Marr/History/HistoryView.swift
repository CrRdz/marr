import AppKit
import MarrCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var store: ConversationHistoryStore
    @State private var searchText = ""
    @State private var selectedConversationID: UUID?
    @State private var conversationPendingDeletion: ConversationHistoryRecord?
    @State private var isConfirmingClearAll = false
    @FocusState private var searchFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    init(controller: MarrController) {
        self.controller = controller
        _store = ObservedObject(wrappedValue: controller.historyStore)
    }

    var body: some View {
        Form {
            Section {
                historyToolbar
            }

            if store.lastErrorMessage != nil {
                Section {
                    ConversationHistoryErrorView(store: store)
                }
            }

            Section("Conversations") {
                if activeConversations.isEmpty {
                    if store.lastErrorMessage == nil {
                        emptyState(
                            title: "No History",
                            systemImage: "clock.arrow.circlepath",
                            description: "Captured conversations will appear here."
                        )
                    }
                } else if filteredConversations.isEmpty {
                    emptyState(
                        title: "No Matches",
                        systemImage: "magnifyingglass",
                        description: "Try a different search."
                    )
                } else {
                    ForEach(filteredConversations) { conversation in
                        historyListRow(conversation)
                    }
                }
            }
        }
        .marrTextStyle(.body)
        .formStyle(.grouped)
        .tint(selectedAccentColor)
        .accentColor(selectedAccentColor)
        .onAppear {
            store.reload()
        }
        .alert(
            "Delete this conversation?",
            isPresented: Binding(
                get: { conversationPendingDeletion != nil },
                set: { if !$0 { conversationPendingDeletion = nil } }
            ),
            presenting: conversationPendingDeletion
        ) { conversation in
            Button("Delete", role: .destructive) {
                store.delete(conversation.id)
                conversationPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                conversationPendingDeletion = nil
            }
        } message: { conversation in
            Text("The conversation and its \(conversation.images.count) stored attachment\(conversation.images.count == 1 ? "" : "s") will be removed.")
        }
        .confirmationDialog(
            "Clear all conversation history?",
            isPresented: $isConfirmingClearAll
        ) {
            Button("Clear History", role: .destructive) {
                selectedConversationID = nil
                store.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var historyToolbar: some View {
        HStack(spacing: MarrUI.Spacing.medium) {
            searchField

            Spacer(minLength: 8)

            Text("\(activeConversations.count) saved")
                .marrTextStyle(.secondary, weight: .regular)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()

            Button(role: .destructive) {
                isConfirmingClearAll = true
            } label: {
                Label("Clear All", marrSymbol: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(store.conversations.isEmpty || controller.activeInferenceRequests > 0)
        }
        .padding(.vertical, 2)
    }

    private var searchField: some View {
        HStack(spacing: MarrUI.Spacing.regular) {
            MarrIcon("magnifyingglass")
                .marrTextStyle(.secondary, weight: .medium)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search history...", text: $searchText)
                .textFieldStyle(.plain)
                .marrTextStyle(.body, weight: .regular)
                .focused($searchFocused)
                .accessibilityLabel("Search history")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    MarrIcon("xmark.circle.fill")
                        .marrTextStyle(.secondary, weight: .semibold)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear history search")
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 190, idealWidth: 240, maxWidth: 280)
        .frame(height: MarrUI.Control.compact)
        .marrSurface(.input, cornerRadius: MarrUI.Radius.control,
                     border: searchFocused ? .focus : .standard, tint: selectedAccentColor)
    }

    private func historyListRow(_ conversation: ConversationHistoryRecord) -> some View {
        MarrHoverRegion { hovered in
            let isActive = selectedConversationID == conversation.id || hovered
            Button {
                selectedConversationID = conversation.id
                controller.openHistoryConversation(conversation)
            } label: {
                HStack(spacing: MarrUI.Spacing.medium) {
                    VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
                        Text(displayTitle(for: conversation))
                            .marrTextStyle(.body, weight: .medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(metadata(for: conversation))
                            .marrTextStyle(.secondary, weight: .regular)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 12)

                    Text(dateLabel(for: conversation.updatedAt))
                        .marrTextStyle(.secondary, weight: .regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 46)
                .background(
                    RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                        .fill(isActive ? selectedAccentColor.opacity(0.09) : .clear)
                )
                .overlay {
                    if isActive && contrast == .increased {
                        RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous)
                            .strokeBorder(MarrUI.Border.color(.standard, increasedContrast: true), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: MarrUI.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Archive") { store.setArchived(conversation.id, archived: true) }
                    .disabled(controller.activeInferenceRequests > 0)
                Menu("Move to workspace") {
                    Button("No workspace") { store.assignConversation(conversation.id, to: nil) }
                    ForEach(store.workspaces) { workspace in
                        Button(workspace.name) { store.assignConversation(conversation.id, to: workspace.id) }
                    }
                }.disabled(controller.activeInferenceRequests > 0)
                Button("Delete", role: .destructive) {
                    conversationPendingDeletion = conversation
                }.disabled(controller.activeInferenceRequests > 0)
            }
        }
    }

    private func emptyState(title: String, systemImage: String, description: String) -> some View {
        VStack(spacing: MarrUI.Spacing.regular) {
            MarrIcon(systemImage, size: MarrUI.Icon.hero)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .marrTextStyle(.title, weight: .semibold)

            Text(description)
                .marrTextStyle(.secondary, weight: .regular, paragraph: true)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
    }

    private var activeConversations: [ConversationHistoryRecord] { store.conversations.filter { !$0.isArchived } }

    private var filteredConversations: [ConversationHistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return activeConversations
        }

        return activeConversations.filter {
            searchCorpus(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    private func searchCorpus(for conversation: ConversationHistoryRecord) -> String {
        var parts = [conversation.title]
        for turn in conversation.turns {
            parts.append(turn.question)
            parts.append(turn.answer)
            if let errorMessage = turn.errorMessage {
                parts.append(errorMessage)
            }
        }
        parts.append(contentsOf: conversation.images.map(\.fileName))
        return parts.joined(separator: " ")
    }

    private func metadata(for conversation: ConversationHistoryRecord) -> String {
        var parts: [String] = []
        let turnCount = conversation.turns.count
        let attachmentCount = conversation.images.count

        if turnCount > 0 {
            parts.append("\(turnCount) turn\(turnCount == 1 ? "" : "s")")
        }
        if attachmentCount > 0 {
            parts.append("\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Untitled" : parts.joined(separator: " · ")
    }

    private func dateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if let hours = calendar.dateComponents([.hour], from: date, to: now).hour, hours < 48 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: now)
        }

        let formatter = DateFormatter()
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d, y")
        }
        return formatter.string(from: date)
    }

    private func displayTitle(for conversation: ConversationHistoryRecord) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled conversation" : title
    }

    private var selectedAccentColor: Color {
        selectedAccent.color
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

struct ConversationHistoryErrorView: View {
    @ObservedObject var store: ConversationHistoryStore

    var body: some View {
        if let error = store.lastErrorMessage {
            VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                MarrStatusLabel(.error, title: "History needs attention")
                Text(verbatim: error)
                    .marrTextStyle(.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !store.conversations.isEmpty {
                    Text("Showing previously loaded conversations.")
                        .marrTextStyle(.secondary)
                        .foregroundStyle(.secondary)
                }
                Button("Reload history") { store.reload() }
                    .controlSize(.small)
                    .help("Try reading saved conversations again")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MarrUI.Spacing.medium)
            .marrSurface(.card)
        }
    }
}
