import Foundation
import Combine

struct ConversationImageAsset: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let mimeType: String
    let fileName: String

    init(id: UUID, data: Data, mimeType: String, fileName: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }

    init(id: UUID = UUID(), image: PickedImage) {
        self.id = id
        data = image.data
        mimeType = image.mimeType
        fileName = image.fileName
    }
}

enum ConversationTurnStatus: String, Codable, Equatable, Sendable {
    case loading
    case completed
    case failed
}

struct ConversationTurn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let question: String
    let imageIDs: [UUID]
    var answer: String
    var errorMessage: String?
    var status: ConversationTurnStatus
    var showsAssistant: Bool

    var isLoading: Bool {
        status == .loading
    }
}

enum VisionMessageRole: String, Equatable, Sendable {
    case user
    case assistant
}

enum VisionContent: Equatable, Sendable {
    case text(String)
    case image(ConversationImageAsset)
}

struct VisionMessage: Equatable, Sendable {
    let role: VisionMessageRole
    let content: [VisionContent]
}

struct VisionRequest: Equatable, Sendable {
    let systemPrompt: String
    let messages: [VisionMessage]
}

struct ConversationContextPolicy: Equatable, Sendable {
    var maximumCompletedTurns = 12
    var maximumTextCharacters = 24_000
    var maximumImages = 4

    static let `default` = ConversationContextPolicy()
}

struct ConversationContextBuilder: Sendable {
    static let systemPrompt = """
    You answer questions about screenshots. Answer the latest user question directly and use earlier turns only when they are relevant.

    Images belong to the user message where they appear. A newly attached image is new visual context and may differ from earlier screenshots. Do not claim that two screenshots are the same unless the user says so. When the question is ambiguous, prefer the most recently attached image.
    """

    let policy: ConversationContextPolicy

    init(policy: ConversationContextPolicy = .default) {
        self.policy = policy
    }

    func build(
        turns: [ConversationTurn],
        images: [UUID: ConversationImageAsset],
        through targetTurnID: UUID
    ) -> VisionRequest? {
        guard let targetIndex = turns.firstIndex(where: { $0.id == targetTurnID }) else {
            return nil
        }

        let target = turns[targetIndex]
        let completed = turns[..<targetIndex].filter {
            $0.status == .completed && !$0.answer.isEmpty
        }
        let selectedCompleted = selectCompletedTurns(Array(completed))
        var selected = selectedCompleted + [target]
        let latestImageID = turns[...targetIndex].reversed().lazy.flatMap(\.imageIDs).first
        selected = enforceImageBudget(
            selected,
            targetID: target.id,
            fallbackImageID: latestImageID
        )

        var messages: [VisionMessage] = []
        for turn in selected {
            var userContent: [VisionContent] = turn.imageIDs.compactMap { imageID in
                images[imageID].map(VisionContent.image)
            }
            userContent.append(.text(turn.question))
            messages.append(VisionMessage(role: .user, content: userContent))

            if turn.id != target.id, !turn.answer.isEmpty {
                messages.append(VisionMessage(role: .assistant, content: [.text(turn.answer)]))
            }
        }

        return VisionRequest(systemPrompt: Self.systemPrompt, messages: messages)
    }

    private func selectCompletedTurns(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        var selected: [ConversationTurn] = []
        var characterCount = 0

        for turn in turns.reversed() {
            guard selected.count < policy.maximumCompletedTurns else { break }
            let turnCharacters = turn.question.count + turn.answer.count
            guard selected.isEmpty || characterCount + turnCharacters <= policy.maximumTextCharacters else {
                break
            }
            selected.append(turn)
            characterCount += turnCharacters
        }

        return selected.reversed()
    }

    private func enforceImageBudget(
        _ turns: [ConversationTurn],
        targetID: UUID,
        fallbackImageID: UUID?
    ) -> [ConversationTurn] {
        var remainingImages = max(1, policy.maximumImages)
        var result = turns

        for index in result.indices.reversed() {
            let imageIDs = result[index].imageIDs
            if imageIDs.count <= remainingImages {
                remainingImages -= imageIDs.count
            } else {
                result[index] = ConversationTurn(
                    id: result[index].id,
                    question: result[index].question,
                    imageIDs: Array(imageIDs.suffix(remainingImages)),
                    answer: result[index].answer,
                    errorMessage: result[index].errorMessage,
                    status: result[index].status,
                    showsAssistant: result[index].showsAssistant
                )
                remainingImages = 0
            }
        }

        if !result.contains(where: { !$0.imageIDs.isEmpty }),
           let targetIndex = result.firstIndex(where: { $0.id == targetID }),
           let fallbackImageID {
            result[targetIndex] = ConversationTurn(
                id: result[targetIndex].id,
                question: result[targetIndex].question,
                imageIDs: [fallbackImageID],
                answer: result[targetIndex].answer,
                errorMessage: result[targetIndex].errorMessage,
                status: result[targetIndex].status,
                showsAssistant: result[targetIndex].showsAssistant
            )
        }

        return result
    }
}

@MainActor
final class ConversationSession: ObservableObject {
    let id: UUID
    let createdAt: Date
    @Published private(set) var turns: [ConversationTurn]
    @Published private(set) var images: [UUID: ConversationImageAsset]
    @Published private(set) var pendingImageIDs: [UUID]
    @Published var focusRequestID = 0

    private let contextBuilder: ConversationContextBuilder
    private var updatedAt: Date
    private var archiveHandler: ((ConversationArchive) -> Void)?

    init(
        initialImage: PickedImage,
        initialQuestion: String,
        contextBuilder: ConversationContextBuilder = ConversationContextBuilder()
    ) {
        id = UUID()
        createdAt = Date()
        updatedAt = createdAt
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

    var hasLoadingTurn: Bool {
        turns.contains(where: \.isLoading)
    }

    func setArchiveHandler(_ handler: @escaping (ConversationArchive) -> Void) {
        archiveHandler = handler
        handler(makeArchive())
    }

    @discardableResult
    func appendScreenshot(_ image: PickedImage) -> UUID {
        let asset = ConversationImageAsset(image: image)
        images[asset.id] = asset
        pendingImageIDs.append(asset.id)
        focusRequestID += 1
        archiveChanges()
        return asset.id
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

    func complete(_ turnID: UUID, answer: String) {
        update(turnID) {
            $0.answer = answer
            $0.errorMessage = nil
            $0.status = .completed
            $0.showsAssistant = true
        }
        focusRequestID += 1
        archiveChanges()
    }

    func fail(_ turnID: UUID, message: String) {
        update(turnID) {
            $0.answer = ""
            $0.errorMessage = message
            $0.status = .failed
            $0.showsAssistant = true
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
        archiveChanges()
        return true
    }

    private func update(_ turnID: UUID, mutation: (inout ConversationTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        mutation(&turns[index])
    }

    private func archiveChanges() {
        updatedAt = Date()
        archiveHandler?(makeArchive())
    }

    private func makeArchive() -> ConversationArchive {
        ConversationArchive(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            turns: turns,
            images: Array(images.values),
            pendingImageIDs: pendingImageIDs
        )
    }
}
