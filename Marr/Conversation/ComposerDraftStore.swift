import Foundation
import Combine
import MarrCore

struct ComposerDraftKey: Codable, Hashable {
    let conversationID: UUID?
    let workspaceID: UUID?
    let taskID: UUID?

    static func conversation(_ id: UUID) -> Self {
        Self(conversationID: id, workspaceID: nil, taskID: nil)
    }

    static func work(workspaceID: UUID?, taskID: UUID?) -> Self {
        Self(conversationID: nil, workspaceID: workspaceID, taskID: taskID)
    }

    var isWork: Bool { conversationID == nil }
}

struct ComposerMentionBinding: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case skill, file, integration }
    let kind: Kind
    let name: String
    let path: String
    var reference: String
    var id: String { "\(kind.rawValue):\(path)" }

    func ranges(in text: String, workspaceURL: URL?) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: #"[$@]"#) else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).compactMap { match in
            guard let token = AgentComposerCompletion.token(in: text, caretUTF16: NSMaxRange(match.range)),
                  token.replacementRange.location == match.range.location else { return nil }
            var value = String(token.originalText.dropFirst())
            if kind == .skill {
                return token.kind == .skill && value.trimmingCharacters(in: CharacterSet(charactersIn: ".:!?")) == name
                    ? token.replacementRange : nil
            }
            guard token.kind == .file else { return nil }
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if kind == .integration { return value == reference ? token.replacementRange : nil }
            let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : workspaceURL?.appendingPathComponent(value)
            return url?.standardizedFileURL.path == path ? token.replacementRange : nil
        }
    }
}

struct ComposerDraft: Equatable {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var editingTurnID: UUID?
    var attachments: [ConversationImageAsset] = []
    var bindings: [ComposerMentionBinding] = []

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && bindings.isEmpty && editingTurnID == nil
    }
}

/// Draft metadata and attachment bytes live together under App Support. Assets
/// use UUID filenames; names supplied by users never become filesystem paths.
@MainActor
final class ComposerDraftStore: ObservableObject {
    @Published private(set) var lastErrorMessage: String?
    private(set) var drafts: [ComposerDraftKey: ComposerDraft] = [:]
    private(set) var recoveries: [CodexSubmissionDraft] = []
    let rootURL: URL
    private var isReadable = true
    private var persistedAssetIDs: Set<UUID> = []

    private struct Asset: Codable {
        let id: UUID
        let mimeType: String
        let fileName: String
    }
    private struct Record: Codable {
        let key: ComposerDraftKey
        let text: String
        let selectionLocation: Int
        let selectionLength: Int
        let editingTurnID: UUID?
        let attachments: [Asset]
        let bindings: [ComposerMentionBinding]
    }
    private struct Recovery: Codable {
        let id: UUID
        let workspaceID: UUID?
        let taskID: UUID?
        let threadID: String?
        let prompt: String
        let attachments: [Asset]
        let bindings: [ComposerMentionBinding]
        let error: String?
    }
    private struct Manifest: Codable {
        var version = 1
        let drafts: [Record]
        let recoveries: [Recovery]
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        load()
    }

    func draft(for key: ComposerDraftKey) -> ComposerDraft { drafts[key] ?? ComposerDraft() }

    @discardableResult
    func save(_ draft: ComposerDraft, for key: ComposerDraftKey) -> Bool {
        guard drafts[key] != draft else { return lastErrorMessage == nil || persist() }
        if draft.isEmpty { drafts.removeValue(forKey: key) }
        else { drafts[key] = draft }
        return persist()
    }

    @discardableResult
    func move(from oldKey: ComposerDraftKey, to newKey: ComposerDraftKey) -> Bool {
        guard oldKey != newKey, let draft = drafts.removeValue(forKey: oldKey) else { return true }
        let existing = drafts[newKey] ?? ComposerDraft()
        drafts[newKey] = Self.merging(existing, with: draft)
        return persist()
    }

    @discardableResult
    func retainRecovery(_ draft: CodexSubmissionDraft) -> Bool {
        recoveries.removeAll { $0.id == draft.id }
        recoveries.append(draft)
        return persist()
    }

    @discardableResult
    func removeRecovery(_ id: UUID) -> Bool {
        recoveries.removeAll { $0.id == id }
        return persist()
    }

    static func merging(_ current: ComposerDraft, with incoming: ComposerDraft) -> ComposerDraft {
        let merged = CodexDraftMerge.merge(currentPrompt: current.text, currentAttachments: current.attachments,
                                          recoveredPrompt: incoming.text, recoveredAttachments: incoming.attachments)
        var result = current
        result.text = current.text == incoming.text ? current.text : merged.prompt
        result.attachments = merged.attachments
        result.selection = current.text.isEmpty ? incoming.selection : NSRange(location: result.text.utf16.count, length: 0)
        result.editingTurnID = current.editingTurnID ?? incoming.editingTurnID
        for binding in incoming.bindings where !result.bindings.contains(where: { $0.id == binding.id }) {
            result.bindings.append(binding)
        }
        return result
    }

    private var manifestURL: URL { rootURL.appendingPathComponent("drafts.json") }
    private var assetsURL: URL { rootURL.appendingPathComponent("assets", isDirectory: true) }

    private func load() {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            func assets(_ records: [Asset]) throws -> [ConversationImageAsset] {
                try records.map {
                    ConversationImageAsset(id: $0.id,
                        data: try Data(contentsOf: assetsURL.appendingPathComponent($0.id.uuidString)),
                        mimeType: $0.mimeType, fileName: $0.fileName)
                }
            }
            var loaded: [ComposerDraftKey: ComposerDraft] = [:]
            for record in manifest.drafts {
                let location = min(max(0, record.selectionLocation), record.text.utf16.count)
                let length = min(max(0, record.selectionLength), record.text.utf16.count - location)
                loaded[record.key] = ComposerDraft(text: record.text,
                    selection: NSRange(location: location, length: length),
                    editingTurnID: record.editingTurnID, attachments: try assets(record.attachments),
                    bindings: record.bindings)
            }
            let recovered = try manifest.recoveries.map {
                CodexSubmissionDraft(id: $0.id, prompt: $0.prompt, attachments: try assets($0.attachments),
                    workspaceID: $0.workspaceID, taskID: $0.taskID, threadID: $0.threadID,
                    bindings: $0.bindings, error: $0.error ?? "Sending was interrupted before confirmation. Check the original task before sending again.")
            }
            drafts = loaded
            recoveries = recovered
            persistedAssetIDs = Set(loaded.values.flatMap(\.attachments).map(\.id)
                + recovered.flatMap(\.attachments).map(\.id))
        } catch {
            isReadable = false
            lastErrorMessage = "Saved drafts could not be read. The existing files have been kept: \(error.localizedDescription)"
        }
    }

    private func persist() -> Bool {
        guard isReadable else { return false }
        do {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            func assets(_ values: [ConversationImageAsset]) throws -> [Asset] {
                try values.map { asset in
                    let url = assetsURL.appendingPathComponent(asset.id.uuidString)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try asset.data.write(to: url, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                    return Asset(id: asset.id, mimeType: asset.mimeType, fileName: asset.fileName)
                }
            }
            let records = try drafts.map { key, draft in
                Record(key: key, text: draft.text, selectionLocation: draft.selection.location,
                       selectionLength: draft.selection.length, editingTurnID: draft.editingTurnID,
                       attachments: try assets(draft.attachments), bindings: draft.bindings)
            }
            let recoveries = try recoveries.map {
                Recovery(id: $0.id, workspaceID: $0.workspaceID, taskID: $0.taskID, threadID: $0.threadID,
                         prompt: $0.prompt, attachments: try assets($0.attachments),
                         bindings: $0.bindings, error: $0.error)
            }
            let data = try JSONEncoder().encode(Manifest(drafts: records, recoveries: recoveries))
            try data.write(to: manifestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            let retained = Set(records.flatMap(\.attachments).map(\.id) + recoveries.flatMap(\.attachments).map(\.id))
            if retained != persistedAssetIDs {
                for url in try FileManager.default.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil) {
                    if let id = UUID(uuidString: url.lastPathComponent), !retained.contains(id) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            persistedAssetIDs = retained
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "This draft could not be saved: \(error.localizedDescription)"
            return false
        }
    }
}
