import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var controller: MarrController
    @ObservedObject private var store: ConversationHistoryStore
    @State private var selection: UUID?
    @State private var hoveredConversationID: UUID?
    @State private var conversationPendingDeletion: ConversationHistoryRecord?
    @AppStorage(MarrAccentColor.storageKey) private var accentColor = MarrAccentColor.system.rawValue

    init(controller: MarrController) {
        self.controller = controller
        _store = ObservedObject(wrappedValue: controller.historyStore)
    }

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
                    List(store.conversations) { conversation in
                        Button {
                            selection = conversation.id
                        } label: {
                            historyRow(
                                conversation,
                                isActive: selection == conversation.id || hoveredConversationID == conversation.id
                            )
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
                    .listStyle(.sidebar)
                }
            }
            .navigationTitle("History")
        } detail: {
            if let conversation = selectedConversation {
                ConversationHistoryDetail(
                    controller: controller,
                    store: store,
                    conversation: conversation
                )
            } else {
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "text.bubble"
                )
            }
        }
        .frame(minWidth: 760, idealWidth: 840, minHeight: 500, idealHeight: 560)
        .toolbar(removing: .sidebarToggle)
        .tint(selectedAccentColor)
        .accentColor(selectedAccentColor)
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

    private func historyRow(_ conversation: ConversationHistoryRecord, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail(for: conversation)

            VStack(alignment: .leading, spacing: 6) {
                Text(displayTitle(for: conversation))
                    .font(MarrTypography.body(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? selectedAccent.foregroundColor : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                    Text("\(conversation.turns.count) turn\(conversation.turns.count == 1 ? "" : "s")")
                    if !conversation.images.isEmpty {
                        Label("\(conversation.images.count)", systemImage: "photo")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(MarrTypography.caption2())
                .foregroundStyle(isActive ? selectedAccent.secondaryForegroundColor : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? selectedAccentColor : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func thumbnail(for conversation: ConversationHistoryRecord) -> some View {
        let imageIDs = imageIDs(for: conversation)
        if !imageIDs.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(Array(imageIDs.prefix(3).enumerated()).reversed(), id: \.element) { index, imageID in
                    if let image = store.nsImage(conversationID: conversation.id, imageID: imageID) {
                        stackedThumbnailImage(image, index: index)
                    }
                }
            }
            .frame(width: 50, height: 42, alignment: .topLeading)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary)
                Image(systemName: "text.bubble")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 46, height: 38)
        }
    }

    private func stackedThumbnailImage(_ image: NSImage, index: Int) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 46, height: 38)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.34), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(index == 0 ? 0.10 : 0.06), radius: 2, x: 0, y: 1)
            .offset(x: CGFloat(index) * 3, y: CGFloat(index) * 2)
    }

    private func imageIDs(for conversation: ConversationHistoryRecord) -> [UUID] {
        let turnImageIDs = conversation.turns.flatMap(\.imageIDs)
        let allImageIDs = turnImageIDs + conversation.pendingImageIDs + conversation.images.map(\.id)
        return Array(NSOrderedSet(array: allImageIDs).compactMap { $0 as? UUID })
    }

    private func displayTitle(for conversation: ConversationHistoryRecord) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled conversation" : title
    }

    private func selectMostRecentIfNeeded() {
        guard selection == nil || !store.conversations.contains(where: { $0.id == selection }) else {
            return
        }
        selection = store.conversations.first?.id
    }

    private var selectedAccentColor: Color {
        selectedAccent.color
    }

    private var selectedAccent: MarrAccentColor {
        MarrAccentColor.resolve(accentColor)
    }
}

private struct ConversationHistoryDetail: View {
    @ObservedObject var controller: MarrController
    @ObservedObject var store: ConversationHistoryStore
    let conversation: ConversationHistoryRecord

    @State private var question = ""
    @State private var submittingTurnID: UUID?
    @State private var hoveredQuestionTurnID: UUID?
    @State private var previewImage: HistoryImagePreview?
    @AppStorage(MarrBubbleColor.storageKey) private var bubbleColor = MarrBubbleColor.system.rawValue
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    ForEach(conversation.turns) { turn in
                        turnView(turn)
                    }

                    if !conversation.pendingImageIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Unsent attachments", systemImage: "paperclip")
                                .font(MarrTypography.display(size: 17, weight: .semibold))
                            imageGrid(ids: conversation.pendingImageIDs)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            composer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            questionFocused = true
        }
        .onChange(of: conversation.id) { _, _ in
            question = ""
            submittingTurnID = nil
            hoveredQuestionTurnID = nil
            previewImage = nil
            questionFocused = true
        }
        .sheet(item: $previewImage) { preview in
            HistoryImagePreviewView(preview: preview)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(conversation.title)
                .font(MarrTypography.display(size: 22, weight: .semibold))
                .textSelection(.enabled)
            Text(conversation.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(MarrTypography.caption())
                .foregroundStyle(.secondary)
        }
    }

    private func turnView(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.imageIDs.isEmpty {
                imageGrid(ids: turn.imageIDs)
            }

            HStack(alignment: .bottom) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(turn.question)
                        .font(MarrTypography.body(size: 13, weight: .medium))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(bubbleForegroundColor)
                        .background(bubbleTint, in: RoundedRectangle(cornerRadius: 14))

                    if hoveredQuestionTurnID == turn.id {
                        questionActions(for: turn)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .onHover { isHovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        hoveredQuestionTurnID = isHovering ? turn.id : nil
                    }
                }
            }

            switch turn.status {
            case .completed:
                if !turn.answer.isEmpty {
                    Text(markdown: turn.answer)
                        .textSelection(.enabled)
                        .font(MarrTypography.body(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
            case .failed:
                statusMessage(
                    turn.errorMessage ?? "Request failed",
                    systemImage: "exclamationmark.triangle",
                    color: .red
                )
            case .loading:
                statusMessage(
                    "This request did not finish before the session ended.",
                    systemImage: "clock",
                    color: .secondary
                )
            }
        }
    }

    private func questionActions(for turn: ConversationTurn) -> some View {
        HStack(spacing: 10) {
            Text(conversation.updatedAt, format: .dateTime.hour().minute())

            Button {
                question = turn.question
                questionFocused = true
            } label: {
                Label("Edit", systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .help("Edit this question")
        }
        .font(MarrTypography.caption())
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
    }

    private func statusMessage(_ message: String, systemImage: String, color: Color) -> some View {
        Label(message, systemImage: systemImage)
            .font(MarrTypography.body(size: 13, weight: .medium))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }

    private func imageGrid(ids: [UUID]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
            ForEach(ids, id: \.self) { imageID in
                if let image = store.nsImage(conversationID: conversation.id, imageID: imageID) {
                    Button {
                        previewImage = HistoryImagePreview(id: imageID, image: image)
                    } label: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help("Open image")
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .frame(height: 120)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask a follow-up", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MarrTypography.body(size: 15))
                .lineLimit(1...3)
                .focused($questionFocused)
                .onSubmit {
                    sendCurrentQuestion()
                }

            Button {
                sendCurrentQuestion()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? bubbleForegroundColor : .white)
            .background(canSend ? bubbleTint : Color.secondary.opacity(0.46), in: Circle())
            .shadow(color: .black.opacity(canSend ? 0.16 : 0.04), radius: 7, x: 0, y: 3)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend)
            .help("Send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .frame(minHeight: 46)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
    }

    private var canSend: Bool {
        submittingTurnID == nil && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bubbleTint: Color {
        selectedBubbleColor.color
    }

    private var bubbleForegroundColor: Color {
        selectedBubbleColor.foregroundColor
    }

    private var selectedBubbleColor: MarrBubbleColor {
        MarrBubbleColor.resolve(bubbleColor)
    }

    private func sendCurrentQuestion() {
        let rawQuestion = question
        let trimmedQuestion = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, submittingTurnID == nil else {
            return
        }

        guard let turnID = store.beginTurn(conversationID: conversation.id, question: trimmedQuestion) else {
            return
        }

        question = ""
        submittingTurnID = turnID

        guard let request = store.request(conversationID: conversation.id, through: turnID) else {
            store.failTurn(conversationID: conversation.id, turnID: turnID, message: "Could not build the conversation context.")
            submittingTurnID = nil
            return
        }

        Task {
            do {
                let response = try await controller.submit(request: request)
                await MainActor.run {
                    store.completeTurn(conversationID: conversation.id, turnID: turnID, answer: response)
                    submittingTurnID = nil
                    questionFocused = true
                }
            } catch {
                await MainActor.run {
                    store.failTurn(
                        conversationID: conversation.id,
                        turnID: turnID,
                        message: controller.userFacingMessage(for: error)
                    )
                    submittingTurnID = nil
                    questionFocused = true
                }
            }
        }
    }
}

private struct HistoryImagePreview: Identifiable {
    let id: UUID
    let image: NSImage
}

private struct HistoryImagePreviewView: View {
    let preview: HistoryImagePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(12)

            Image(nsImage: preview.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(.regularMaterial)
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
