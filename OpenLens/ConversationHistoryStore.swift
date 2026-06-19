import AppKit
import Combine
import Foundation

struct ConversationImageReference: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let mimeType: String
    let fileName: String
    let storedFileName: String
}

struct ConversationHistoryRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var turns: [ConversationTurn]
    var images: [ConversationImageReference]
    var pendingImageIDs: [UUID]

    var title: String {
        turns.first?.question ?? "Untitled conversation"
    }

    var completedTurnCount: Int {
        turns.filter { $0.status == .completed }.count
    }
}

struct ConversationArchive: Sendable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let turns: [ConversationTurn]
    let images: [ConversationImageAsset]
    let pendingImageIDs: [UUID]
}

@MainActor
final class ConversationHistoryStore: ObservableObject {
    @Published private(set) var conversations: [ConversationHistoryRecord] = []
    @Published private(set) var lastErrorMessage: String?

    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(rootURL: applicationSupport.appendingPathComponent("OpenLens/History", isDirectory: true))
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        reload()
    }

    func save(_ archive: ConversationArchive) {
        do {
            let conversationURL = directoryURL(for: archive.id)
            let imagesURL = conversationURL.appendingPathComponent("images", isDirectory: true)
            try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)

            let references = try archive.images.map { image in
                let storedFileName = image.id.uuidString + fileExtension(for: image.mimeType)
                let imageURL = imagesURL.appendingPathComponent(storedFileName)
                if !fileManager.fileExists(atPath: imageURL.path) {
                    try image.data.write(to: imageURL, options: .atomic)
                }
                return ConversationImageReference(
                    id: image.id,
                    mimeType: image.mimeType,
                    fileName: image.fileName,
                    storedFileName: storedFileName
                )
            }

            let record = ConversationHistoryRecord(
                id: archive.id,
                createdAt: archive.createdAt,
                updatedAt: archive.updatedAt,
                turns: archive.turns,
                images: references.sorted { $0.id.uuidString < $1.id.uuidString },
                pendingImageIDs: archive.pendingImageIDs
            )
            let manifestURL = conversationURL.appendingPathComponent("conversation.json")
            try encoder.encode(record).write(to: manifestURL, options: .atomic)
            upsert(record)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Could not save conversation history: \(error.localizedDescription)"
        }
    }

    func delete(_ conversationID: UUID) {
        do {
            let url = directoryURL(for: conversationID)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            conversations.removeAll { $0.id == conversationID }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Could not delete conversation history: \(error.localizedDescription)"
        }
    }

    func imageData(conversationID: UUID, imageID: UUID) -> Data? {
        guard
            let conversation = conversations.first(where: { $0.id == conversationID }),
            let image = conversation.images.first(where: { $0.id == imageID })
        else {
            return nil
        }

        let url = directoryURL(for: conversationID)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(image.storedFileName)
        return try? Data(contentsOf: url)
    }

    func nsImage(conversationID: UUID, imageID: UUID) -> NSImage? {
        imageData(conversationID: conversationID, imageID: imageID).flatMap(NSImage.init(data:))
    }

    func reload() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let directories = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            conversations = directories.compactMap { directory in
                let manifestURL = directory.appendingPathComponent("conversation.json")
                guard let data = try? Data(contentsOf: manifestURL) else { return nil }
                return try? decoder.decode(ConversationHistoryRecord.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            lastErrorMessage = nil
        } catch {
            conversations = []
            lastErrorMessage = "Could not load conversation history: \(error.localizedDescription)"
        }
    }

    private func upsert(_ record: ConversationHistoryRecord) {
        if let index = conversations.firstIndex(where: { $0.id == record.id }) {
            conversations[index] = record
        } else {
            conversations.append(record)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func directoryURL(for conversationID: UUID) -> URL {
        rootURL.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func fileExtension(for mimeType: String) -> String {
        mimeType == "image/png" ? ".png" : ".jpg"
    }
}
