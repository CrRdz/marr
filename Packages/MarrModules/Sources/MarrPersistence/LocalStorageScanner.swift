import Foundation
import MarrCore

/// Reports logical file bytes once per physical file. Directory and external-folder
/// sizes are intentionally excluded, and symbolic links are never followed.
enum LocalStorageScanner {
    static func scan(rootURL: URL, archivedAttachmentNames: Set<String>, conversationCount: Int,
                     archivedConversationCount: Int, workspaceCount: Int,
                     fileManager: FileManager) -> LocalStorageReport {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .fileResourceIdentifierKey]
        var warnings: [String] = []
        var bytes: [LocalStorageCategory.Kind: Int64] = [:]
        var seenFiles = Set<AnyHashable>()
        let root = rootURL.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                      options: [], errorHandler: { url, error in
            warnings.append("Could not inspect \(url.lastPathComponent): \(error.localizedDescription)")
            return true
        }) else {
            return LocalStorageReport(rootURL: root, categories: [], conversationCount: conversationCount,
                                      archivedConversationCount: archivedConversationCount, workspaceCount: workspaceCount,
                                      warnings: ["Could not inspect Marr's storage folder."])
        }
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }
                if let identifier = values.fileResourceIdentifier as? AnyHashable,
                   !seenFiles.insert(identifier).inserted { continue }
                guard url.standardizedFileURL.path.hasPrefix(prefix) else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                let kind: LocalStorageCategory.Kind
                if ["marr.sqlite", "marr.sqlite-wal", "marr.sqlite-shm"].contains(relative) { kind = .database }
                else if relative.hasPrefix("Attachments/") {
                    kind = archivedAttachmentNames.contains(url.lastPathComponent) ? .archivedAttachments : .attachments
                } else if relative.hasPrefix("Workspaces/") { kind = .workspaceData }
                else { kind = .other }
                bytes[kind, default: 0] += Int64(max(0, values.fileSize ?? 0))
            } catch {
                warnings.append("Could not inspect \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return LocalStorageReport(rootURL: root, categories: LocalStorageCategory.Kind.allCases.map {
            LocalStorageCategory(kind: $0, bytes: bytes[$0, default: 0])
        }, conversationCount: conversationCount, archivedConversationCount: archivedConversationCount,
                                  workspaceCount: workspaceCount, warnings: warnings)
    }
}
