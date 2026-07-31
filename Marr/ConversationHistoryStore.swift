import AppKit
import Combine
import Foundation
import MarrCore
import MarrPersistence

@MainActor
final class ConversationHistoryStore: ObservableObject {
    @Published private(set) var conversations: [ConversationHistoryRecord] = []
    @Published private(set) var lastErrorMessage: String?

    private let attachmentsURL: URL
    private let legacyHistoryURL: URL
    private let repository: ConversationHistoryRepository
    private var operationTask: Task<Void, Never>?

    convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(rootURL: applicationSupport.appendingPathComponent("Marr", isDirectory: true))
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        attachmentsURL = rootURL.appendingPathComponent("Attachments", isDirectory: true)
        legacyHistoryURL = rootURL.appendingPathComponent("History", isDirectory: true)
        repository = ConversationHistoryRepository(rootURL: rootURL, fileManager: fileManager)
        reload()
    }

    func save(_ archive: ConversationArchive) {
        enqueue(errorPrefix: "Could not save conversation history") { repository in
            try repository.save(archive)
        }
    }

    func delete(_ conversationID: UUID) {
        enqueue(errorPrefix: "Could not delete conversation history") { repository in
            try repository.delete(conversationID)
        }
    }

    func deleteAll() {
        enqueue(errorPrefix: "Could not clear conversation history") { repository in
            try repository.deleteAll()
        }
    }

    func reload() {
        enqueue(errorPrefix: "Could not load conversation history", clearsOnFailure: true) { repository in
            try repository.reload()
        }
    }

    func imageData(conversationID: UUID, imageID: UUID) -> Data? {
        imageFileURLs(conversationID: conversationID, imageID: imageID)
            .lazy
            .compactMap { try? Data(contentsOf: $0) }
            .first
    }

    func imageFileURLs(conversationID: UUID, imageID: UUID) -> [URL] {
        guard
            let conversation = conversations.first(where: { $0.id == conversationID }),
            let image = conversation.images.first(where: { $0.id == imageID })
        else {
            return []
        }

        return [
            attachmentsURL.appendingPathComponent(image.storedFileName),
            legacyHistoryURL
                .appendingPathComponent(conversationID.uuidString, isDirectory: true)
                .appendingPathComponent("images", isDirectory: true)
                .appendingPathComponent(image.storedFileName)
        ]
    }

    func nsImage(conversationID: UUID, imageID: UUID) -> NSImage? {
        imageData(conversationID: conversationID, imageID: imageID).flatMap(NSImage.init(data:))
    }

    func waitForPendingOperations() async {
        let task = operationTask
        await task?.value
    }

    private func enqueue(
        errorPrefix: String,
        clearsOnFailure: Bool = false,
        operation: @escaping @Sendable (ConversationHistoryRepository) throws -> [ConversationHistoryRecord]
    ) {
        let previousTask = operationTask
        let repository = repository

        operationTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .utility) {
                Result { try operation(repository) }
            }.value

            guard let self else { return }
            switch result {
            case .success(let records):
                conversations = records
                lastErrorMessage = nil
            case .failure(let error):
                if clearsOnFailure {
                    conversations = []
                }
                lastErrorMessage = "\(errorPrefix): \(error.localizedDescription)"
            }
        }
    }
}

struct TokenUsageEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let inputTokens: Int
    let outputTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }
}

@MainActor
final class TokenUsageStore: ObservableObject {
    @Published private(set) var events: [TokenUsageEvent] = []

    private let fileURL: URL

    convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(rootURL: applicationSupport.appendingPathComponent("Marr", isDirectory: true))
    }

    init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent("token-usage.json")
        load()
    }

    func record(_ usage: InferenceTokenUsage, at date: Date = Date()) {
        guard usage.totalTokens > 0 else { return }
        events.append(TokenUsageEvent(
            id: UUID(),
            date: date,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens
        ))
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        events = (try? decoder.decode([TokenUsageEvent].self, from: data)) ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(events).write(to: fileURL, options: .atomic)
        } catch {
            // Usage telemetry must never interrupt an inference request.
        }
    }
}
