import Foundation
import MarrCore
import MarrPersistence
import Testing
import SQLite3

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
            generatedTitle: "Saved screenshot answer",
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
        #expect(saved.title == "Saved screenshot answer")
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

    @Test("Document attachment keeps its filename extension and MIME type")
    func documentAttachmentRoundTrip() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("MarrPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let attachmentID = UUID()
        let conversationID = UUID()
        let documentData = Data("%PDF-1.7 test".utf8)
        let archive = ConversationArchive(
            id: conversationID,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            generatedTitle: nil,
            turns: [
                ConversationTurn(
                    id: UUID(),
                    question: "Summarize this",
                    imageIDs: [attachmentID],
                    answer: "Summary",
                    errorMessage: nil,
                    status: .completed,
                    showsAssistant: true
                )
            ],
            images: [
                ConversationImageAsset(
                    id: attachmentID,
                    data: documentData,
                    mimeType: "application/pdf",
                    fileName: "report.pdf"
                )
            ],
            pendingImageIDs: []
        )

        let repository = ConversationHistoryRepository(rootURL: rootURL)
        _ = try repository.save(archive)

        let attachmentURL = rootURL
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("\(attachmentID.uuidString).pdf")
        #expect(try Data(contentsOf: attachmentURL) == documentData)

        let reloaded = try #require(try ConversationHistoryRepository(rootURL: rootURL).reload().first)
        let reference = try #require(reloaded.images.first)
        #expect(reference.mimeType == "application/pdf")
        #expect(reference.fileName == "report.pdf")
        #expect(reference.storedFileName.hasSuffix(".pdf"))
    }

    @Test("Workspace metadata and archived conversations persist across restart")
    func workspaceAndArchiveRoundTrip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConversationHistoryRepository(rootURL: root)
        let bookmark = Data([1, 2, 3, 255])
        let workspace = try repository.createWorkspace(name: "  Research  ", path: "/some/user/folder", bookmark: bookmark)
        #expect(workspace.name == "Research")
        let archive = sampleArchive(workspaceID: workspace.id)
        _ = try repository.save(archive)
        _ = try repository.setArchived(archive.id, archived: true)
        // A stale streaming snapshot cannot accidentally restore an archived chat.
        _ = try repository.save(archive)
        let restored = ConversationHistoryRepository(rootURL: root)
        let record = try #require(try restored.reload().first)
        #expect(record.workspaceID == workspace.id && record.isArchived)
        #expect(try restored.workspaces().first?.bookmark == bookmark)
        try restored.renameWorkspace(workspace.id, name: "Renamed")
        #expect(try repository.workspaces().first?.name == "Renamed")
        _ = try restored.setArchived(archive.id, archived: false)
        let staleArchivedSnapshot = ConversationArchive(id: archive.id, createdAt: archive.createdAt, updatedAt: archive.updatedAt,
            turns: archive.turns, images: archive.images, pendingImageIDs: [], workspaceID: workspace.id, archivedAt: record.archivedAt)
        _ = try restored.save(staleArchivedSnapshot)
        #expect(try restored.reload().first?.isArchived == false)
    }

    @Test("Removing a workspace detaches its chats and preserves the user's folder")
    func removeWorkspacePreservesConversationsAndFolder() throws {
        let root = temporaryRoot()
        let folder = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sentinel = folder.appendingPathComponent("user-file.txt")
        try Data("keep me".utf8).write(to: sentinel)
        let repository = ConversationHistoryRepository(rootURL: root)
        let workspace = try repository.createWorkspace(name: "Workspace", path: folder.path)
        let archive = sampleArchive(workspaceID: workspace.id)
        _ = try repository.save(archive)
        let records = try repository.removeWorkspace(workspace.id)
        #expect(records.count == 1 && records[0].id == archive.id && records[0].workspaceID == nil)
        #expect(try Data(contentsOf: sentinel) == Data("keep me".utf8))
        #expect(try repository.workspaces().isEmpty)
        // A queued save captured before removal must remain detached and still save its content.
        #expect(try repository.save(archive).first?.workspaceID == nil)
        let replacement = try repository.createWorkspace(name: "Replacement")
        _ = try repository.assignConversation(archive.id, to: replacement.id)
        #expect(try repository.save(archive).first?.workspaceID == replacement.id)
        #expect(try ConversationHistoryRepository(rootURL: root).reload().first?.turns.first?.answer == "answer")
    }

    @Test("Version 2 SQLite history migrates without losing messages or titles")
    func sqliteMigration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID(), turnID = UUID()
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("marr.sqlite").path, &database) == SQLITE_OK)
        let sql = """
        CREATE TABLE conversations (id TEXT PRIMARY KEY NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, generated_title TEXT);
        CREATE TABLE turns (id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL, position INTEGER NOT NULL, question TEXT NOT NULL, answer TEXT NOT NULL, error_message TEXT, status TEXT NOT NULL, shows_assistant INTEGER NOT NULL, FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE);
        INSERT INTO conversations VALUES ('\(id.uuidString)', '2026-10-25T00:00:00.000Z', '2026-10-25T00:01:00.000Z', 'Old title');
        INSERT INTO turns VALUES ('\(turnID.uuidString)', '\(id.uuidString)', 0, 'Old question', 'Old answer', NULL, 'completed', 1);
        PRAGMA user_version = 2;
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let repository = ConversationHistoryRepository(rootURL: root)
        let record = try #require(try repository.reload().first)
        #expect(record.id == id && record.title == "Old title")
        #expect(record.turns.first?.answer == "Old answer")
        #expect(record.workspaceID == nil && !record.isArchived)
        let workspace = try repository.createWorkspace(name: "New workspace")
        #expect(try repository.assignConversation(id, to: workspace.id).first?.workspaceID == workspace.id)
        #expect(try repository.assignConversation(id, to: nil).first?.workspaceID == nil)
    }

    @Test("Legacy JSON history decodes new optional metadata and migrates attachments")
    func legacyJSONMigration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let directory = root.appendingPathComponent("History").appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("""
        {"id":"\(id.uuidString)","createdAt":"2026-10-25T00:00:00Z","updatedAt":"2026-10-25T00:00:00Z","turns":[],"images":[],"pendingImageIDs":[]}
        """.utf8)
        try data.write(to: directory.appendingPathComponent("conversation.json"))
        let record = try #require(try ConversationHistoryRepository(rootURL: root).reload().first)
        #expect(record.id == id && record.workspaceID == nil && !record.isArchived)
    }

    @Test("Storage categories measure only Marr files and exclude external symlinks")
    func storageAccounting() throws {
        let root = temporaryRoot(), external = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        let repository = ConversationHistoryRepository(rootURL: root)
        _ = try repository.createWorkspace(name: "Research", path: external.path)
        let active = sampleArchive(image: .init(data: Data(repeating: 1, count: 31), mimeType: "image/png", fileName: "first.png"))
        let archived = sampleArchive(image: .init(data: Data(repeating: 2, count: 47), mimeType: "image/png", fileName: "second.png"))
        _ = try repository.save(active)
        _ = try repository.save(archived)
        _ = try repository.setArchived(archived.id, archived: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Workspaces"), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 59).write(to: root.appendingPathComponent("Workspaces/metadata.bin"))
        try Data(repeating: 4, count: 71).write(to: root.appendingPathComponent("other.bin"))
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 8192).write(to: external.appendingPathComponent("private-file.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external-link"), withDestinationURL: external)
        let report = try repository.storageReport()
        #expect(report.categories.first { $0.kind == .database }!.bytes > 0)
        #expect(report.categories.first { $0.kind == .attachments }?.bytes == 31)
        #expect(report.categories.first { $0.kind == .archivedAttachments }?.bytes == 47)
        #expect(report.categories.first { $0.kind == .workspaceData }?.bytes == 59)
        #expect(report.categories.first { $0.kind == .other }?.bytes == 71)
        #expect(report.conversationCount == 2 && report.archivedConversationCount == 1 && report.workspaceCount == 1)
        #expect(report.warnings.isEmpty)
        let reportAgain = try repository.storageReport()
        #expect(reportAgain.totalBytes == report.totalBytes)
    }

    @Test("Invalid workspace association rolls back the whole conversation update")
    func invalidWorkspaceDoesNotLoseConversation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConversationHistoryRepository(rootURL: root)
        let archive = sampleArchive()
        _ = try repository.save(archive)
        let invalid = ConversationArchive(id: UUID(), createdAt: archive.createdAt, updatedAt: Date(), turns: [], images: [], pendingImageIDs: [], workspaceID: UUID())
        #expect(throws: (any Error).self) { try repository.save(invalid) }
        #expect(try repository.reload().first?.turns.first?.answer == "answer")
        #expect(throws: (any Error).self) { try repository.createWorkspace(name: "  ") }
    }

    @Test("Delayed snapshots cannot resurrect chats after delete or delete all")
    func deletedSnapshotsCannotReturn() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConversationHistoryRepository(rootURL: root)
        let first = sampleArchive(image: .init(data: Data([1, 2, 3]), mimeType: "image/png", fileName: "first.png"))
        let second = sampleArchive()
        _ = try repository.save(first)
        _ = try repository.delete(first.id)
        #expect(try repository.save(first).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Attachments").path).isEmpty)
        _ = try repository.save(second)
        _ = try repository.deleteAll()
        #expect(try repository.save(second).isEmpty)
        #expect(try repository.reload().isEmpty)
        // New chats still work after clearing storage.
        #expect(try repository.save(sampleArchive()).count == 1)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MarrPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleArchive(workspaceID: UUID? = nil, image: ConversationImageAsset? = nil) -> ConversationArchive {
        ConversationArchive(id: UUID(), createdAt: Date(), updatedAt: Date(), turns: [
            .init(id: UUID(), question: "question", imageIDs: image.map { [$0.id] } ?? [], answer: "answer", errorMessage: nil, status: .completed, showsAssistant: true)
        ], images: image.map { [$0] } ?? [], pendingImageIDs: [], workspaceID: workspaceID)
    }

}
