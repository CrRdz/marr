import Foundation
import MarrCore
import SQLite3

public final class ConversationHistoryRepository: @unchecked Sendable {
    private let rootURL: URL
    private let databaseURL: URL
    private let attachmentsURL: URL
    private let legacyHistoryURL: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private var database: OpaquePointer?
    private var records: [ConversationHistoryRecord] = []

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        databaseURL = rootURL.appendingPathComponent("marr.sqlite")
        attachmentsURL = rootURL.appendingPathComponent("Attachments", isDirectory: true)
        legacyHistoryURL = rootURL.appendingPathComponent("History", isDirectory: true)
        self.fileManager = fileManager
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func save(_ archive: ConversationArchive) throws -> [ConversationHistoryRecord] {
        try prepareDatabase()

        let candidateFileURLs = archive.images.compactMap { image -> URL? in
            let storedFileName = image.id.uuidString + fileExtension(for: image.mimeType)
            let url = attachmentsURL.appendingPathComponent(storedFileName)
            return fileManager.fileExists(atPath: url.path) ? nil : url
        }
        var didCommitRecord = false

        do {
            let references = try saveAttachments(archive.images, conversationID: archive.id)
            let record = ConversationHistoryRecord(
                id: archive.id,
                createdAt: archive.createdAt,
                updatedAt: archive.updatedAt,
                generatedTitle: archive.generatedTitle,
                turns: archive.turns,
                images: references.sorted { $0.id.uuidString < $1.id.uuidString },
                pendingImageIDs: archive.pendingImageIDs
            )
            try saveRecord(record)
            didCommitRecord = true
            upsert(record)
            try? cleanupUnreferencedAttachments()
            return records
        } catch {
            if !didCommitRecord {
                for url in candidateFileURLs where fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw error
        }
    }

    public func delete(_ conversationID: UUID) throws -> [ConversationHistoryRecord] {
        try prepareDatabase()
        let record = records.first(where: { $0.id == conversationID })
        let attachmentURLs = record?
            .images
            .map { attachmentsURL.appendingPathComponent($0.storedFileName) } ?? []
        let legacyURL = legacyDirectoryURL(for: conversationID)
        try execute("DELETE FROM conversations WHERE id = ?", [conversationID.uuidString])

        do {
            let stagedDeletion = try stageForDeletion(attachmentURLs + [legacyURL])
            records.removeAll { $0.id == conversationID }
            stagedDeletion.discard(using: fileManager)
            return records
        } catch {
            if let record {
                try? saveRecord(record)
            }
            throw error
        }
    }

    public func deleteAll() throws -> [ConversationHistoryRecord] {
        try prepareDatabase()
        let previousRecords = records
        try execute("DELETE FROM conversations")
        var stagedDeletion: StagedDeletion?

        do {
            stagedDeletion = try stageForDeletion([attachmentsURL, legacyHistoryURL])
            try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
            records.removeAll()
            stagedDeletion?.discard(using: fileManager)
            return records
        } catch {
            if fileManager.fileExists(atPath: attachmentsURL.path) {
                try? fileManager.removeItem(at: attachmentsURL)
            }
            stagedDeletion?.restore(using: fileManager)
            for record in previousRecords {
                try? saveRecord(record)
            }
            throw error
        }
    }

    public func reload() throws -> [ConversationHistoryRecord] {
        try prepareDatabase()
        try migrateLegacyHistoryIfNeeded()
        records = try loadRecords()
        try? cleanupUnreferencedAttachments()
        return records
    }

    private func stageForDeletion(_ sourceURLs: [URL]) throws -> StagedDeletion {
        let stagingRoot = rootURL
            .appendingPathComponent(".Trash", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var moves: [StagedDeletion.Move] = []
        do {
            var seenPaths = Set<String>()
            for (index, sourceURL) in sourceURLs.enumerated() {
                guard
                    seenPaths.insert(sourceURL.standardizedFileURL.path).inserted,
                    fileManager.fileExists(atPath: sourceURL.path)
                else {
                    continue
                }

                let stagedURL = stagingRoot.appendingPathComponent(
                    "\(index)-\(sourceURL.lastPathComponent)",
                    isDirectory: sourceURL.hasDirectoryPath
                )
                try fileManager.moveItem(at: sourceURL, to: stagedURL)
                moves.append(.init(originalURL: sourceURL, stagedURL: stagedURL))
            }
            return StagedDeletion(rootURL: stagingRoot, moves: moves)
        } catch {
            StagedDeletion(rootURL: stagingRoot, moves: moves).restore(using: fileManager)
            throw error
        }
    }

    private func cleanupUnreferencedAttachments() throws {
        guard fileManager.fileExists(atPath: attachmentsURL.path) else { return }

        let referencedNames = Set(
            try query("SELECT stored_file_name FROM attachments")
                .map { $0.string("stored_file_name") }
        )
        let fileURLs = try fileManager.contentsOfDirectory(
            at: attachmentsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in fileURLs where !referencedNames.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
    }

    private func prepareDatabase() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        if database == nil {
            guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
                throw SQLiteStoreError.open(message: sqliteMessage)
            }
            try execute("PRAGMA foreign_keys = ON")
        }

        try migrateSchema()
    }

    private func migrateSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                generated_title TEXT
            )
            """)
        let conversationColumns = try query("PRAGMA table_info(conversations)")
            .map { $0.string("name") }
        if !conversationColumns.contains("generated_title") {
            try execute("ALTER TABLE conversations ADD COLUMN generated_title TEXT")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS turns (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                question TEXT NOT NULL,
                answer TEXT NOT NULL,
                error_message TEXT,
                status TEXT NOT NULL,
                shows_assistant INTEGER NOT NULL,
                FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS attachments (
                id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                file_name TEXT NOT NULL,
                stored_file_name TEXT NOT NULL,
                FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS turn_images (
                turn_id TEXT NOT NULL,
                image_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY(turn_id, image_id),
                FOREIGN KEY(turn_id) REFERENCES turns(id) ON DELETE CASCADE,
                FOREIGN KEY(image_id) REFERENCES attachments(id) ON DELETE CASCADE
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS pending_images (
                conversation_id TEXT NOT NULL,
                image_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                PRIMARY KEY(conversation_id, image_id),
                FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
                FOREIGN KEY(image_id) REFERENCES attachments(id) ON DELETE CASCADE
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS turns_conversation_position ON turns(conversation_id, position)")
        try execute("CREATE INDEX IF NOT EXISTS attachments_conversation ON attachments(conversation_id)")
        try execute("PRAGMA user_version = 2")
    }

    private func saveAttachments(
        _ images: [ConversationImageAsset],
        conversationID: UUID
    ) throws -> [ConversationImageReference] {
        try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        return try images.map { image in
            let storedFileName = image.id.uuidString + fileExtension(for: image.mimeType)
            let imageURL = attachmentsURL.appendingPathComponent(storedFileName)
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
    }

    private func saveRecord(_ record: ConversationHistoryRecord) throws {
        try prepareDatabase()
        try transaction {
            try execute(
                """
                INSERT INTO conversations (id, created_at, updated_at, generated_title)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    generated_title = excluded.generated_title
                """,
                [
                    record.id.uuidString,
                    dateString(record.createdAt),
                    dateString(record.updatedAt),
                    record.generatedTitle as Any
                ]
            )
            try execute("DELETE FROM pending_images WHERE conversation_id = ?", [record.id.uuidString])
            try execute("DELETE FROM turn_images WHERE turn_id IN (SELECT id FROM turns WHERE conversation_id = ?)", [record.id.uuidString])
            try execute("DELETE FROM turns WHERE conversation_id = ?", [record.id.uuidString])
            try execute("DELETE FROM attachments WHERE conversation_id = ?", [record.id.uuidString])

            for image in record.images {
                try execute(
                    """
                    INSERT INTO attachments (id, conversation_id, mime_type, file_name, stored_file_name)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    [
                        image.id.uuidString,
                        record.id.uuidString,
                        image.mimeType,
                        image.fileName,
                        image.storedFileName
                    ]
                )
            }

            for (turnIndex, turn) in record.turns.enumerated() {
                try execute(
                    """
                    INSERT INTO turns (id, conversation_id, position, question, answer, error_message, status, shows_assistant)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        turn.id.uuidString,
                        record.id.uuidString,
                        turnIndex,
                        turn.question,
                        turn.answer,
                        turn.errorMessage as Any,
                        turn.status.rawValue,
                        turn.showsAssistant ? 1 : 0
                    ]
                )

                for (imageIndex, imageID) in turn.imageIDs.enumerated() {
                    try execute(
                        "INSERT OR IGNORE INTO turn_images (turn_id, image_id, position) VALUES (?, ?, ?)",
                        [turn.id.uuidString, imageID.uuidString, imageIndex]
                    )
                }
            }

            for (index, imageID) in record.pendingImageIDs.enumerated() {
                try execute(
                    "INSERT OR IGNORE INTO pending_images (conversation_id, image_id, position) VALUES (?, ?, ?)",
                    [record.id.uuidString, imageID.uuidString, index]
                )
            }
        }
    }

    private func loadRecords() throws -> [ConversationHistoryRecord] {
        let rows = try query(
            "SELECT id, created_at, updated_at, generated_title FROM conversations ORDER BY updated_at DESC"
        )

        return try rows.compactMap { row in
            guard
                let id = UUID(uuidString: row.string("id")),
                let createdAt = date(from: row.string("created_at")),
                let updatedAt = date(from: row.string("updated_at"))
            else {
                return nil
            }

            return ConversationHistoryRecord(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                generatedTitle: row.optionalString("generated_title"),
                turns: try loadTurns(conversationID: id),
                images: try loadImages(conversationID: id),
                pendingImageIDs: try loadPendingImageIDs(conversationID: id)
            )
        }
    }

    private func loadTurns(conversationID: UUID) throws -> [ConversationTurn] {
        let rows = try query(
            """
            SELECT id, question, answer, error_message, status, shows_assistant
            FROM turns
            WHERE conversation_id = ?
            ORDER BY position ASC
            """,
            [conversationID.uuidString]
        )

        return rows.compactMap { row in
            guard
                let id = UUID(uuidString: row.string("id")),
                let status = ConversationTurnStatus(rawValue: row.string("status"))
            else {
                return nil
            }

            return ConversationTurn(
                id: id,
                question: row.string("question"),
                imageIDs: loadImageIDs(forTurnID: id),
                answer: row.string("answer"),
                errorMessage: row.optionalString("error_message"),
                status: status,
                showsAssistant: row.int("shows_assistant") != 0
            )
        }
    }

    private func loadImageIDs(forTurnID turnID: UUID) -> [UUID] {
        (try? query(
            "SELECT image_id FROM turn_images WHERE turn_id = ? ORDER BY position ASC",
            [turnID.uuidString]
        ).compactMap { UUID(uuidString: $0.string("image_id")) }) ?? []
    }

    private func loadImages(conversationID: UUID) throws -> [ConversationImageReference] {
        try query(
            """
            SELECT id, mime_type, file_name, stored_file_name
            FROM attachments
            WHERE conversation_id = ?
            ORDER BY id ASC
            """,
            [conversationID.uuidString]
        ).compactMap { row in
            guard let id = UUID(uuidString: row.string("id")) else { return nil }
            return ConversationImageReference(
                id: id,
                mimeType: row.string("mime_type"),
                fileName: row.string("file_name"),
                storedFileName: row.string("stored_file_name")
            )
        }
    }

    private func loadPendingImageIDs(conversationID: UUID) throws -> [UUID] {
        try query(
            "SELECT image_id FROM pending_images WHERE conversation_id = ? ORDER BY position ASC",
            [conversationID.uuidString]
        ).compactMap { UUID(uuidString: $0.string("image_id")) }
    }

    private func migrateLegacyHistoryIfNeeded() throws {
        guard fileManager.fileExists(atPath: legacyHistoryURL.path) else {
            return
        }

        let directories = try fileManager.contentsOfDirectory(
            at: legacyHistoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for directory in directories {
            let manifestURL = directory.appendingPathComponent("conversation.json")
            guard
                let data = try? Data(contentsOf: manifestURL),
                let record = try? decoder.decode(ConversationHistoryRecord.self, from: data),
                !conversationExists(record.id)
            else {
                continue
            }

            try migrateLegacyAttachments(record, from: directory)
            try saveRecord(record)
        }
    }

    private func migrateLegacyAttachments(_ record: ConversationHistoryRecord, from directory: URL) throws {
        let legacyImagesURL = directory.appendingPathComponent("images", isDirectory: true)
        for image in record.images {
            let sourceURL = legacyImagesURL.appendingPathComponent(image.storedFileName)
            let destinationURL = attachmentsURL.appendingPathComponent(image.storedFileName)
            guard fileManager.fileExists(atPath: sourceURL.path),
                  !fileManager.fileExists(atPath: destinationURL.path)
            else {
                continue
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private func conversationExists(_ id: UUID) -> Bool {
        (try? query("SELECT id FROM conversations WHERE id = ? LIMIT 1", [id.uuidString]).isEmpty == false) ?? false
    }

    private func upsert(_ record: ConversationHistoryRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.updatedAt > $1.updatedAt }
    }

    private func legacyDirectoryURL(for conversationID: UUID) -> URL {
        legacyHistoryURL.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func fileExtension(for mimeType: String) -> String {
        mimeType == "image/png" ? ".png" : ".jpg"
    }

    private func dateString(_ date: Date) -> String {
        historyDateFormatter().string(from: date)
    }

    private func date(from string: String) -> Date? {
        historyDateFormatter().date(from: string)
    }

    private func historyDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private extension ConversationHistoryRepository {
    var sqliteMessage: String {
        if let database, let message = sqlite3_errmsg(database) {
            return String(cString: message)
        }
        return "Unknown SQLite error."
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ values: [Any] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare(message: sqliteMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.step(message: sqliteMessage)
        }
    }

    func query(_ sql: String, _ values: [Any] = []) throws -> [SQLiteRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare(message: sqliteMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement)

        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(SQLiteRow(statement: statement))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw SQLiteStoreError.step(message: sqliteMessage)
            }
        }
    }

    func bind(_ values: [Any], to statement: OpaquePointer?) throws {
        for (index, value) in values.enumerated() {
            let sqliteIndex = Int32(index + 1)
            switch value {
            case Optional<Any>.none:
                sqlite3_bind_null(statement, sqliteIndex)
            case let string as String:
                sqlite3_bind_text(statement, sqliteIndex, string, -1, SQLITE_TRANSIENT)
            case let int as Int:
                sqlite3_bind_int64(statement, sqliteIndex, sqlite3_int64(int))
            case let bool as Bool:
                sqlite3_bind_int(statement, sqliteIndex, bool ? 1 : 0)
            case let uuid as UUID:
                sqlite3_bind_text(statement, sqliteIndex, uuid.uuidString, -1, SQLITE_TRANSIENT)
            case let optionalString as String?:
                if let optionalString {
                    sqlite3_bind_text(statement, sqliteIndex, optionalString, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, sqliteIndex)
                }
            default:
                if case Optional<Any>.some(let wrapped) = value {
                    try bind([wrapped], to: statement)
                } else {
                    throw SQLiteStoreError.bind(message: "Unsupported SQLite binding: \(type(of: value))")
                }
            }
        }
    }
}

private struct StagedDeletion {
    struct Move {
        let originalURL: URL
        let stagedURL: URL
    }

    let rootURL: URL
    let moves: [Move]

    func restore(using fileManager: FileManager) {
        for move in moves.reversed() {
            guard fileManager.fileExists(atPath: move.stagedURL.path) else { continue }
            try? fileManager.createDirectory(
                at: move.originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.moveItem(at: move.stagedURL, to: move.originalURL)
        }
        try? fileManager.removeItem(at: rootURL)
    }

    func discard(using fileManager: FileManager) {
        try? fileManager.removeItem(at: rootURL)
    }
}


private struct SQLiteRow {
    private let values: [String: SQLiteValue]

    init(statement: OpaquePointer?) {
        var values: [String: SQLiteValue] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .int(Int(sqlite3_column_int64(statement, index)))
            case SQLITE_NULL:
                values[name] = .null
            default:
                let text = sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
                values[name] = .string(text)
            }
        }
        self.values = values
    }

    func string(_ key: String) -> String {
        switch values[key] {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .null, .none:
            return ""
        }
    }

    func optionalString(_ key: String) -> String? {
        switch values[key] {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .null, .none:
            return nil
        }
    }

    func int(_ key: String) -> Int {
        switch values[key] {
        case .int(let value):
            return value
        case .string(let value):
            return Int(value) ?? 0
        case .null, .none:
            return 0
        }
    }
}

private enum SQLiteValue {
    case string(String)
    case int(Int)
    case null
}

private enum SQLiteStoreError: LocalizedError {
    case open(message: String)
    case prepare(message: String)
    case bind(message: String)
    case step(message: String)

    var errorDescription: String? {
        switch self {
        case .open(let message):
            return "Could not open SQLite database: \(message)"
        case .prepare(let message):
            return "Could not prepare SQLite statement: \(message)"
        case .bind(let message):
            return "Could not bind SQLite value: \(message)"
        case .step(let message):
            return "Could not execute SQLite statement: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
