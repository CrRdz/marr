import Foundation

struct SavedWorkspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var bookmark: Data
    var lastUsedAt: Date
    var isPinned: Bool
    var pinOverride: Bool? = nil
    var projectID: String? = nil
    var projectPosition: Int? = nil
    var projectRecencyAt: Date? = nil

    init(
        id: UUID,
        name: String,
        path: String,
        bookmark: Data,
        lastUsedAt: Date,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, bookmark, lastUsedAt, isPinned, pinOverride, projectID, projectPosition, projectRecencyAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinOverride = try container.decodeIfPresent(Bool.self, forKey: .pinOverride)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        projectPosition = try container.decodeIfPresent(Int.self, forKey: .projectPosition)
        projectRecencyAt = try container.decodeIfPresent(Date.self, forKey: .projectRecencyAt)
    }
}

enum SavedTaskState: String, Codable {
    case ready
    case running
    case completed
    case failed
    case interrupted
}

enum TaskMoveDirection: Equatable { case up, down }
enum TaskPlacement: Equatable { case before, after }

struct SavedTask: Codable, Identifiable, Equatable {
    let id: UUID
    var workspaceID: UUID
    var title: String
    var threadID: String?
    var state: SavedTaskState
    var statusMessage: String
    var latestAgentMessage: String
    var latestDiff: String
    var activities: [WorkActivity]
    var createdAt: Date
    var updatedAt: Date
    var projectID: String? = nil
    var hasCanonicalProject: Bool? = nil
    var isExplicitlyProjectless: Bool? = nil
    var sectionID: String? = nil
    var lastKnownTurnID: String? = nil
}

/// The v1 payload remains backward compatible. Production archives are encoded
/// and atomically written off the UI actor; preferences hold only small metadata.
/// Legacy preference-only stores remain available for isolated/in-memory clients.
