import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: ConversationHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var conversationPendingDeletion: ConversationHistoryRecord?

    var body: some View {
        NavigationSplitView {
            Group {
                if store.conversations.isEmpty {
                    ContentUnavailableView(
                        "No History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Captured conversations will appear here.")
                    )
                } else {
                    List(store.conversations, selection: $selection) { conversation in
                        historyRow(conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    conversationPendingDeletion = conversation
                                }
                            }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Close History")
                }
            }
        } detail: {
            if let conversation = selectedConversation {
                ConversationHistoryDetail(store: store, conversation: conversation)
            } else {
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "text.bubble"
                )
            }
        }
        .frame(minWidth: 760, idealWidth: 840, minHeight: 500, idealHeight: 560)
        .onAppear {
            store.reload()
            selectMostRecentIfNeeded()
        }
        .onChange(of: store.conversations) { _, _ in
            selectMostRecentIfNeeded()
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

    private var selectedConversation: ConversationHistoryRecord? {
        store.conversations.first { $0.id == selection }
    }

    private func historyRow(_ conversation: ConversationHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(conversation.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 7) {
                Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                Text("\(conversation.turns.count) turn\(conversation.turns.count == 1 ? "" : "s")")
                if !conversation.images.isEmpty {
                    Label("\(conversation.images.count)", systemImage: "photo")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func selectMostRecentIfNeeded() {
        guard selection == nil || !store.conversations.contains(where: { $0.id == selection }) else {
            return
        }
        selection = store.conversations.first?.id
    }
}

private struct ConversationHistoryDetail: View {
    @ObservedObject var store: ConversationHistoryStore
    let conversation: ConversationHistoryRecord

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                ForEach(conversation.turns) { turn in
                    turnView(turn)
                }

                if !conversation.pendingImageIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Unsent attachments", systemImage: "paperclip")
                            .font(.headline)
                        imageGrid(ids: conversation.pendingImageIDs)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(conversation.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(conversation.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            Text(conversation.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func turnView(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.imageIDs.isEmpty {
                imageGrid(ids: turn.imageIDs)
            }

            HStack {
                Spacer(minLength: 60)
                Text(turn.question)
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }

            Group {
                switch turn.status {
                case .completed:
                    Text(markdown: turn.answer)
                        .textSelection(.enabled)
                case .failed:
                    Label(turn.errorMessage ?? "Request failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                case .loading:
                    Label("This request did not finish before the session ended.", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func imageGrid(ids: [UUID]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
            ForEach(ids, id: \.self) { imageID in
                if let image = store.nsImage(conversationID: conversation.id, imageID: imageID) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .frame(height: 120)
                }
            }
        }
    }
}

private extension Text {
    init(markdown source: String) {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        self.init((try? AttributedString(markdown: source, options: options)) ?? AttributedString(source))
    }
}
