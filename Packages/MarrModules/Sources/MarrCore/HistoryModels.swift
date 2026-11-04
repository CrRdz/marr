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
    public var workspaceID: UUID?
    public var archivedAt: Date?
    public var isArchived: Bool { archivedAt != nil }

    public init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        generatedTitle: String? = nil,
        turns: [ConversationTurn],
        images: [ConversationImageReference],
        pendingImageIDs: [UUID],
        workspaceID: UUID? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.generatedTitle = generatedTitle
        self.turns = turns
        self.images = images
        self.pendingImageIDs = pendingImageIDs
        self.workspaceID = workspaceID
        self.archivedAt = archivedAt
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
    public let workspaceID: UUID?
    public let archivedAt: Date?

    public init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        generatedTitle: String? = nil,
        turns: [ConversationTurn],
        images: [ConversationImageAsset],
        pendingImageIDs: [UUID],
        workspaceID: UUID? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.generatedTitle = generatedTitle
        self.turns = turns
        self.images = images
        self.pendingImageIDs = pendingImageIDs
        self.workspaceID = workspaceID
        self.archivedAt = archivedAt
    }
}


/// A Marr-owned workspace association. Its optional folder remains owned by the user.
public struct LocalWorkspaceRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String?
    public var bookmark: Data?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, path: String? = nil, bookmark: Data? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct LocalStorageCategory: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case database, attachments, archivedAttachments, workspaceData, other
    }
    public let kind: Kind
    public let bytes: Int64
    public var id: Kind { kind }
    public var title: String {
        switch kind {
        case .database: "Chat database"
        case .attachments: "Attachments"
        case .archivedAttachments: "Archived attachments"
        case .workspaceData: "Workspace data"
        case .other: "Other"
        }
    }
    public init(kind: Kind, bytes: Int64) { self.kind = kind; self.bytes = bytes }
}

/// File-byte accounting for Marr's own root; selected external folders are not traversed.
public struct LocalStorageReport: Equatable, Sendable {
    public let rootURL: URL
    public let scannedAt: Date
    public let categories: [LocalStorageCategory]
    public let conversationCount: Int
    public let archivedConversationCount: Int
    public let workspaceCount: Int
    public let warnings: [String]
    public var totalBytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    public init(rootURL: URL, scannedAt: Date = Date(), categories: [LocalStorageCategory],
                conversationCount: Int, archivedConversationCount: Int, workspaceCount: Int, warnings: [String] = []) {
        self.rootURL = rootURL; self.scannedAt = scannedAt; self.categories = categories
        self.conversationCount = conversationCount; self.archivedConversationCount = archivedConversationCount
        self.workspaceCount = workspaceCount; self.warnings = warnings
    }
}
