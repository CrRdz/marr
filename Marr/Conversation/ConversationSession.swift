import Foundation
import Combine
import MarrCore

@MainActor
final class ConversationSession: ObservableObject {
    let id: UUID
    let createdAt: Date
    @Published private(set) var generatedTitle: String?
    @Published private(set) var turns: [ConversationTurn]
    @Published private(set) var images: [UUID: ConversationImageAsset]
    @Published private(set) var pendingImageIDs: [UUID]
    @Published var focusRequestID = 0
    @Published private(set) var workspaceID: UUID?
    private(set) var archivedAt: Date?
    @Published private(set) var isDeleted = false
    private var hasRequestedPersistence = false

    private let contextBuilder: ConversationContextBuilder
    private var updatedAt: Date
    private var lastStreamingArchiveAt = Date.distantPast
    private var archiveHandler: ((ConversationArchive) -> Void)?

    init(workspaceID: UUID? = nil, contextBuilder: ConversationContextBuilder = ConversationContextBuilder()) {
        self.workspaceID = workspaceID
        id = UUID()
        createdAt = Date()
        updatedAt = createdAt
        generatedTitle = nil
        turns = []
        images = [:]
        pendingImageIDs = []
        self.contextBuilder = contextBuilder
    }

    init(
        initialImage: PickedImage,
        initialQuestion: String,
        contextBuilder: ConversationContextBuilder = ConversationContextBuilder()
    ) {
        id = UUID()
        createdAt = Date()
        updatedAt = createdAt
        generatedTitle = nil
        let asset = ConversationImageAsset(image: initialImage)
        let turn = ConversationTurn(
            id: UUID(),
            question: initialQuestion,
            imageIDs: [asset.id],
            answer: "",
            errorMessage: nil,
            status: .loading,
            showsAssistant: true
        )
        turns = [turn]
        images = [asset.id: asset]
        pendingImageIDs = []
        self.contextBuilder = contextBuilder
    }

    init(
        historyRecord: ConversationHistoryRecord,
        imageAssets: [ConversationImageAsset],
        contextBuilder: ConversationContextBuilder = ConversationContextBuilder()
    ) {
        id = historyRecord.id
        workspaceID = historyRecord.workspaceID
        archivedAt = historyRecord.archivedAt
        createdAt = historyRecord.createdAt
        updatedAt = historyRecord.updatedAt
        generatedTitle = historyRecord.generatedTitle
        turns = historyRecord.turns.map { turn in
            guard turn.status == .loading else {
                return turn
            }
            return ConversationTurn(
                id: turn.id,
                question: turn.question,
                imageIDs: turn.imageIDs,
                answer: turn.answer,
                errorMessage: turn.errorMessage ?? "This request did not finish before the session ended.",
                status: .failed,
                showsAssistant: true
            )
        }
        images = Dictionary(uniqueKeysWithValues: imageAssets.map { ($0.id, $0) })
        pendingImageIDs = historyRecord.pendingImageIDs
        self.contextBuilder = contextBuilder
    }

    func updateStorageMetadata(from record: ConversationHistoryRecord) {
        guard record.id == id else { return }
        workspaceID = record.workspaceID
        archivedAt = record.archivedAt
    }

    var hasLoadingTurn: Bool {
        turns.contains(where: \.isLoading)
    }

    var displayTitle: String {
        let title = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "New conversation" : title
    }

    var latestEditableTurnID: UUID? {
        guard let turn = turns.last, !turn.isLoading else {
            return nil
        }
        return turn.id
    }

    func setArchiveHandler(
        persistImmediately: Bool = true,
        _ handler: @escaping (ConversationArchive) -> Void
    ) {
        archiveHandler = handler
        if persistImmediately {
            hasRequestedPersistence = true
            handler(makeArchive())
        }
    }

    /// Keep a text-only draft discoverable after switching chats or restarting.
    func persistDraftIdentityIfNeeded() {
        guard !hasRequestedPersistence, !isDeleted, let archiveHandler else { return }
        hasRequestedPersistence = true
        archiveHandler(makeArchive())
    }

    func markDeleted() {
        archiveHandler = nil
        isDeleted = true
    }

    @discardableResult
    func appendScreenshot(_ image: PickedImage) -> UUID {
        let asset = ConversationImageAsset(image: image)
        return append(asset)
    }

    @discardableResult
    func appendAttachment(_ attachment: PickedAttachment) -> UUID {
        let asset = ConversationImageAsset(attachment: attachment)
        return append(asset)
    }

    private func append(_ asset: ConversationImageAsset) -> UUID {
        images[asset.id] = asset
        pendingImageIDs.append(asset.id)
        focusRequestID += 1
        archiveChanges()
        return asset.id
    }

    /// Transfers only the selected unsent attachments. Completed turns and other drafts retain their assets.
    func takePendingAttachments(ids: Set<UUID>? = nil) -> [ConversationImageAsset] {
        let transferredIDs = pendingImageIDs.filter { ids?.contains($0) ?? true }
        guard !transferredIDs.isEmpty else { return [] }
        let attachments = transferredIDs.compactMap { images[$0] }
        let referencedIDs = Set(turns.flatMap(\.imageIDs))
        for id in transferredIDs where !referencedIDs.contains(id) {
            images.removeValue(forKey: id)
        }
        let transferredSet = Set(transferredIDs)
        pendingImageIDs.removeAll { transferredSet.contains($0) }
        if !attachments.isEmpty { archiveChanges() }
        return attachments
    }

    func removePendingAttachment(_ id: UUID) {
        _ = takePendingAttachments(ids: [id])
    }

    /// Restores only the unsent composer assets, without touching sent turns.
    func replacePendingAttachments(_ attachments: [ConversationImageAsset]) {
        guard pendingImageIDs != attachments.map(\.id)
                || attachments.contains(where: { images[$0.id] != $0 }) else { return }
        let referenced = Set(turns.flatMap(\.imageIDs))
        let incomingIDs = Set(attachments.map(\.id))
        for id in pendingImageIDs where !referenced.contains(id) && !incomingIDs.contains(id) {
            images.removeValue(forKey: id)
        }
        for asset in attachments { images[asset.id] = asset }
        pendingImageIDs = attachments.map(\.id)
        archiveChanges()
    }

    /// Called only before the initial screenshot request has been dispatched.
    func takeUnsubmittedInitialTurn(_ turnID: UUID) -> (question: String, attachments: [ConversationImageAsset])? {
        guard turns.count == 1, let turn = turns.first, turn.id == turnID,
              turn.isLoading, turn.answer.isEmpty, turn.errorMessage == nil else { return nil }
        let attachments = turn.imageIDs.compactMap { images[$0] }
        turns = []
        for id in turn.imageIDs where !pendingImageIDs.contains(id) { images.removeValue(forKey: id) }
        archiveChanges()
        return (turn.question, attachments)
    }

    func requestFocus() {
        focusRequestID += 1
    }

    func beginTurn(question rawQuestion: String) -> UUID? {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !hasLoadingTurn else { return nil }

        let turn = ConversationTurn(
            id: UUID(),
            question: question,
            imageIDs: pendingImageIDs,
            answer: "",
            errorMessage: nil,
            status: .loading,
            showsAssistant: false
        )
        pendingImageIDs = []
        turns.append(turn)
        archiveChanges()
        return turn.id
    }

    func request(for turnID: UUID) -> VisionRequest? {
        contextBuilder.build(turns: turns, images: images, through: turnID)
    }

    func revealAssistant(for turnID: UUID) {
        update(turnID) { $0.showsAssistant = true }
    }

    func reviseLatestTurn(_ turnID: UUID, question rawQuestion: String) -> Bool {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !question.isEmpty,
            !hasLoadingTurn,
            turns.last?.id == turnID,
            let index = turns.indices.last
        else {
            return false
        }

        turns[index].question = question
        turns[index].answer = ""
        turns[index].errorMessage = nil
        turns[index].status = .loading
        turns[index].showsAssistant = true
        turns[index].retryAt = nil
        turns[index].retryAttempt = nil
        archiveChanges()
        return true
    }

    func complete(_ turnID: UUID, answer: String) {
        guard turns.first(where: { $0.id == turnID })?.isLoading == true else { return }
        update(turnID) {
            $0.answer = answer
            $0.errorMessage = nil
            $0.status = .completed
            $0.showsAssistant = true
            $0.retryAt = nil
            $0.retryAttempt = nil
        }
        focusRequestID += 1
        archiveChanges()
    }

    func setGeneratedTitle(_ rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != generatedTitle else { return }
        generatedTitle = title
        archiveChanges()
    }

    func fail(_ turnID: UUID, message: String) {
        update(turnID) {
            $0.errorMessage = message
            $0.status = .failed
            $0.showsAssistant = true
            $0.retryAt = nil
            $0.retryAttempt = nil
        }
        focusRequestID += 1
        archiveChanges()
    }

    func prepareRetry(_ turnID: UUID) -> Bool {
        guard let index = turns.firstIndex(where: { $0.id == turnID }), turns[index].status == .failed else {
            return false
        }
        turns[index].answer = ""
        turns[index].errorMessage = nil
        turns[index].status = .loading
        turns[index].showsAssistant = true
        turns[index].retryAt = nil
        turns[index].retryAttempt = nil
        archiveChanges()
        return true
    }

    func receive(_ event: VisionResponseEvent, for turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }), turns[index].isLoading else { return }
        switch event {
        case .text(let answer):
            turns[index].answer = answer
            turns[index].showsAssistant = true
            turns[index].retryAt = nil
            turns[index].retryAttempt = nil
        case .requestStarted:
            turns[index].retryAt = nil
            turns[index].retryAttempt = nil
        case let .retryScheduled(attempt, resumeAt):
            turns[index].showsAssistant = true
            turns[index].retryAt = resumeAt
            turns[index].retryAttempt = attempt
        case .usage: return
        }
        // Persist partial progress without rewriting attachment archives for every token.
        if Date().timeIntervalSince(lastStreamingArchiveAt) >= 0.5 {
            lastStreamingArchiveAt = Date()
            archiveChanges()
        }
    }

    private func update(_ turnID: UUID, mutation: (inout ConversationTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        mutation(&turns[index])
    }

    private func archiveChanges() {
        updatedAt = Date()
        guard !isDeleted else { return }
        hasRequestedPersistence = true
        archiveHandler?(makeArchive())
    }

    private func makeArchive() -> ConversationArchive {
        ConversationArchive(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            generatedTitle: generatedTitle,
            turns: turns,
            images: Array(images.values),
            pendingImageIDs: pendingImageIDs,
            workspaceID: workspaceID,
            archivedAt: archivedAt
        )
    }
}
