import AppKit
import MarrCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var store: ConversationHistoryStore
    @State private var searchText = ""
    @State private var selectedConversationID: UUID?
    @State private var hoveredConversationID: UUID?
    @State private var conversationPendingDeletion: ConversationHistoryRecord?
    @State private var isConfirmingClearAll = false
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

            Section("Conversations") {
                if store.conversations.isEmpty {
                    emptyState(
                        title: "No History",
                        systemImage: "clock.arrow.circlepath",
                        description: "Captured conversations will appear here."
                    )
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
            Text("The conversation and its \(conversation.images.count) stored screenshot\(conversation.images.count == 1 ? "" : "s") will be removed.")
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
        HStack(spacing: 12) {
            searchField

            Spacer(minLength: 8)

            Text("\(store.conversations.count) saved")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(role: .destructive) {
                isConfirmingClearAll = true
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(store.conversations.isEmpty)
        }
        .padding(.vertical, 2)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search history...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 190, idealWidth: 240, maxWidth: 280)
        .frame(height: 28)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.82),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.separator.opacity(0.68), lineWidth: 0.7)
        )
    }

    private func historyListRow(_ conversation: ConversationHistoryRecord) -> some View {
        let isActive = selectedConversationID == conversation.id || hoveredConversationID == conversation.id

        return Button {
            selectedConversationID = conversation.id
            controller.openHistoryConversation(conversation)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(for: conversation))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(metadata(for: conversation))
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 12)

                Text(dateLabel(for: conversation.updatedAt))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? selectedAccentColor.opacity(0.09) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredConversationID = isHovering ? conversation.id : nil
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                conversationPendingDeletion = conversation
            }
        }
    }

    private func emptyState(title: String, systemImage: String, description: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Text(description)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
    }

    private var filteredConversations: [ConversationHistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return store.conversations
        }

        return store.conversations.filter {
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
        return parts.joined(separator: " ")
    }

    private func metadata(for conversation: ConversationHistoryRecord) -> String {
        var parts: [String] = []
        let turnCount = conversation.turns.count
        let imageCount = conversation.images.count

        if turnCount > 0 {
            parts.append("\(turnCount) turn\(turnCount == 1 ? "" : "s")")
        }
        if imageCount > 0 {
            parts.append("\(imageCount) capture\(imageCount == 1 ? "" : "s")")
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
