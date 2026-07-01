import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var store: ConversationHistoryStore
    @State private var searchText = ""
    @State private var selectedConversationID: UUID?
    @State private var hoveredConversationID: UUID?
    @State private var conversationPendingDeletion: ConversationHistoryRecord?
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    init(controller: MarrController) {
        self.controller = controller
        _store = ObservedObject(wrappedValue: controller.historyStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            searchField

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredConversations) { conversation in
                            historyListRow(conversation)
                            if conversation.id != filteredConversations.last?.id {
                                Divider()
                                    .padding(.leading, 24)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("History")
                .font(MarrTypography.display(size: 30, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Text("\(store.conversations.count) saved")
                .font(MarrTypography.body(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search history...", text: $searchText)
                .textFieldStyle(.plain)
                .font(MarrTypography.body(size: 17))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.78), lineWidth: 1)
        )
    }

    private func historyListRow(_ conversation: ConversationHistoryRecord) -> some View {
        let isActive = selectedConversationID == conversation.id || hoveredConversationID == conversation.id

        return Button {
            selectedConversationID = conversation.id
            controller.openHistoryConversation(conversation)
        } label: {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle(for: conversation))
                        .font(MarrTypography.body(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(metadata(for: conversation))
                        .font(MarrTypography.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 16)

                Text(dateLabel(for: conversation.updatedAt))
                    .font(MarrTypography.body(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 24)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? selectedAccentColor.opacity(0.11) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
