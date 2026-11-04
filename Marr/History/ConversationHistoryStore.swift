import AppKit
import Combine
import Foundation
import MarrCore
import MarrPersistence

@MainActor
final class ConversationHistoryStore: ObservableObject {
    @Published private(set) var conversations: [ConversationHistoryRecord] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var workspaces: [LocalWorkspaceRecord] = []
    @Published private(set) var storageReport: LocalStorageReport?
    @Published private(set) var isLoadingStorage = false
    @Published private(set) var deletedConversationIDs: Set<UUID> = []
    let rootURL: URL

    private let attachmentsURL: URL
    private let legacyHistoryURL: URL
    private let repository: ConversationHistoryRepository
    private var operationTask: Task<Void, Never>?

    convenience init() {
        self.init(rootURL: MarrStorage.rootURL)
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        attachmentsURL = rootURL.appendingPathComponent("Attachments", isDirectory: true)
        legacyHistoryURL = rootURL.appendingPathComponent("History", isDirectory: true)
        repository = ConversationHistoryRepository(rootURL: rootURL, fileManager: fileManager)
        reload()
    }

    func save(_ archive: ConversationArchive) {
        guard !deletedConversationIDs.contains(archive.id) else { return }
        enqueue(errorPrefix: "Could not save conversation history") { repository in
            try repository.save(archive)
        }
    }

    func delete(_ conversationID: UUID) {
        enqueue(errorPrefix: "Could not delete conversation history", deletedIDs: [conversationID]) { repository in
            try repository.delete(conversationID)
        }
    }

    func deleteAll() {
        enqueue(errorPrefix: "Could not clear conversation history", marksRemovedRecordsDeleted: true) { repository in
            try repository.deleteAll()
        }
    }

    func reload() {
        enqueue(errorPrefix: "Could not load conversation history") { repository in
            try repository.reload()
        }
    }

    func setArchived(_ id: UUID, archived: Bool) {
        enqueue(errorPrefix: archived ? "Could not archive conversation" : "Could not restore conversation") {
            try $0.setArchived(id, archived: archived)
        }
    }

    func assignConversation(_ id: UUID, to workspaceID: UUID?) {
        enqueue(errorPrefix: "Could not move conversation") { try $0.assignConversation(id, to: workspaceID) }
    }

    func renameWorkspace(_ id: UUID, name: String) {
        enqueue(errorPrefix: "Could not rename workspace") { repository in
            try repository.renameWorkspace(id, name: name)
            return try repository.reload()
        }
    }

    func removeWorkspace(_ id: UUID) {
        enqueue(errorPrefix: "Could not remove workspace") { try $0.removeWorkspace(id) }
    }

    func createWorkspace(name: String, path: String? = nil, bookmark: Data? = nil) async throws -> LocalWorkspaceRecord {
        let previous = operationTask
        let repository = repository
        let task = Task { @MainActor [weak self] () throws -> LocalWorkspaceRecord in
            await previous?.value
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let created = try repository.createWorkspace(name: name, path: path, bookmark: bookmark)
                    return (created, try repository.workspaces())
                }.value
                self?.workspaces = result.1
                self?.lastErrorMessage = nil
                return result.0
            } catch {
                self?.lastErrorMessage = "Could not create workspace: \(error.localizedDescription)"
                throw error
            }
        }
        operationTask = Task { _ = try? await task.value }
        return try await task.value
    }

    func refreshStorage() {
        guard !isLoadingStorage else { return }
        isLoadingStorage = true
        let previous = operationTask
        let repository = repository
        operationTask = Task { @MainActor [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .utility) { Result { try repository.storageReport() } }.value
            guard let self else { return }
            isLoadingStorage = false
            switch result {
            case .success(let report):
                storageReport = report
                lastErrorMessage = nil
            case .failure(let error):
                lastErrorMessage = "Could not measure local storage: \(error.localizedDescription)"
            }
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
        deletedIDs: Set<UUID> = [],
        marksRemovedRecordsDeleted: Bool = false,
        operation: @escaping @Sendable (ConversationHistoryRepository) throws -> [ConversationHistoryRecord]
    ) {
        let previousTask = operationTask
        let repository = repository

        operationTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }

            let result = await Task.detached(priority: .utility) {
                Result { (try operation(repository), try repository.workspaces()) }
            }.value

            guard let self else { return }
            switch result {
            case .success(let snapshot):
                if marksRemovedRecordsDeleted {
                    deletedConversationIDs.formUnion(Set(conversations.map(\.id)).subtracting(snapshot.0.map(\.id)))
                }
                deletedConversationIDs.formUnion(deletedIDs)
                conversations = snapshot.0
                workspaces = snapshot.1
                lastErrorMessage = nil
            case .failure(let error):
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
        self.init(rootURL: MarrStorage.rootURL)
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
