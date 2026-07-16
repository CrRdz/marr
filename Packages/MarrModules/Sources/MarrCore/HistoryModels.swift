import Foundation

public struct ConversationImageReference: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let mimeType: String
    public let fileName: String
    public let storedFileName: String

    public init(id: UUID, mimeType: String, fileName: String, storedFileName: String) {
        self.id = id
        self.mimeType = mimeType
        self.fileName = fileName
        self.storedFileName = storedFileName
    }
}

public struct ConversationHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var generatedTitle: String?
    public var turns: [ConversationTurn]
    public var images: [ConversationImageReference]
    public var pendingImageIDs: [UUID]

    public init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        generatedTitle: String? = nil,
        turns: [ConversationTurn],
        images: [ConversationImageReference],
        pendingImageIDs: [UUID]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.generatedTitle = generatedTitle
        self.turns = turns
        self.images = images
        self.pendingImageIDs = pendingImageIDs
    }

    public var title: String {
        let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return generated.isEmpty ? turns.first?.question ?? "Untitled conversation" : generated
    }
    public var completedTurnCount: Int { turns.filter { $0.status == .completed }.count }
}

public struct ConversationArchive: Sendable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let generatedTitle: String?
    public let turns: [ConversationTurn]
    public let images: [ConversationImageAsset]
    public let pendingImageIDs: [UUID]

    public init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        generatedTitle: String? = nil,
        turns: [ConversationTurn],
        images: [ConversationImageAsset],
        pendingImageIDs: [UUID]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.generatedTitle = generatedTitle
        self.turns = turns
        self.images = images
        self.pendingImageIDs = pendingImageIDs
    }
}
