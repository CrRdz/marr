import Foundation
import MarrCore
import MarrPersistence
import Testing

@Suite("Conversation history repository")
struct ConversationHistoryRepositoryTests {
    @Test("Archive round-trips through SQLite and attachment storage")
    func saveReloadAndDelete() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("MarrPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let imageID = UUID()
        let conversationID = UUID()
        let archive = ConversationArchive(
            id: conversationID,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            turns: [
                ConversationTurn(
                    id: UUID(),
                    question: "question",
                    imageIDs: [imageID],
                    answer: "answer",
                    errorMessage: nil,
                    status: .completed,
                    showsAssistant: true
                )
            ],
            images: [
                ConversationImageAsset(
                    id: imageID,
                    data: Data([0x89, 0x50, 0x4E, 0x47]),
                    mimeType: "image/png",
                    fileName: "capture.png"
                )
            ],
            pendingImageIDs: []
        )

        let repository = ConversationHistoryRepository(rootURL: rootURL)
        let saved = try #require(try repository.save(archive).first)
        #expect(saved.id == conversationID)
        #expect(saved.turns.first?.answer == "answer")

        let attachmentURL = rootURL
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(imageID.uuidString).png")
        #expect(fileManager.fileExists(atPath: attachmentURL.path))

        let reloadedRepository = ConversationHistoryRepository(rootURL: rootURL)
        let reloaded = try #require(try reloadedRepository.reload().first)
        #expect(reloaded == saved)

        #expect(try reloadedRepository.delete(conversationID).isEmpty)
        #expect(!fileManager.fileExists(atPath: attachmentURL.path))
        #expect(try reloadedRepository.reload().isEmpty)
    }
}
