import Foundation
import CryptoKit
import ImageIO

/// An allowlisted, read-only bridge. Never export drafts, credentials or the
/// complete desktop state, and never write back to Codex's private JSON file.
struct CodexDesktopSidebarSnapshot: Codable, Equatable, Sendable {
    var version = 2
    let projects: [Project]
    let projectOrder: [String]
    let pinnedProjectIDs: [String]
    let taskOrder: [String: [String]]
    let chatSort: String
    let projectSort: String
    let grouping: String
    var pinnedSort = "manual"
    var threadProjects: [String: String]? = nil
    var projectlessThreadIDs: [String]? = nil
    var threadWorkspaceRoots: [String: String]? = nil

    struct Project: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let roots: [String]
    }

    static func parse(_ data: Data, codexHome: String) throws -> Self {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let local = json["local-projects"] as? [String: [String: Any]],
              let pins = json["pinned-project-ids"] as? [String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let mappings = json["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]] ?? [:]
        let mapping = mappings["local:\(codexHome)"] ?? [:]
        func canonical(_ id: String) -> String { mapping[id] ?? id }
        let atoms = json["electron-persisted-atom-state"] as? [String: Any] ?? [:]
        let legacy = atoms["flat-project-sidebar-preferences-v1"] as? [String: Any] ?? [:]
        func normalizedSort(_ raw: String?, legacyMode: Bool) -> String {
            guard raw == "manual", !legacyMode || legacy["manualSortVersion"] as? Int == 1 else { return "updated_at" }
            return "manual"
        }
        let sharedSort = atoms["codex-sidebar-sort-mode-v1"] as? String
        let chatSort = normalizedSort(sharedSort ?? legacy["chatSortMode"] as? String, legacyMode: sharedSort == nil)
        let projectSort = normalizedSort(sharedSort ?? legacy["projectSortMode"] as? String, legacyMode: sharedSort == nil)
        let projects = local.values.compactMap { value -> Project? in
            guard let id = value["id"] as? String, let name = value["name"] as? String,
                  let roots = value["rootPaths"] as? [String], roots.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
            return Project(id: canonical(id), name: name, roots: roots)
        }.sorted { $0.id < $1.id }
        let orders = json["sidebar-project-thread-orders"] as? [String: [String]] ?? [:]
        var canonicalOrders: [String: [String]] = [:]
        for (id, order) in orders { canonicalOrders[canonical(id)] = order }
        let hosts = json["thread-project-membership-host-ids"] as? [String: String] ?? [:]
        func isLocal(_ thread: String) -> Bool { hosts[thread] == nil || hosts[thread] == "local" }
        let assignments = json["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        var threadProjects: [String: String] = [:]
        for (thread, assignment) in assignments where isLocal(thread) {
            guard assignment["projectKind"] as? String == "local",
                  let id = assignment["projectId"] as? String, local[id] != nil || mapping.values.contains(id) else { continue }
            threadProjects[thread] = canonical(id)
        }
        let projectless = (json["projectless-thread-ids"] as? [String] ?? []).filter(isLocal)
        let roots = (json["thread-workspace-root-hints"] as? [String: String] ?? [:])
            .filter { isLocal($0.key) && $0.value.hasPrefix("/") }
        return Self(projects: projects, projectOrder: (json["project-order"] as? [String] ?? []).map(canonical),
            pinnedProjectIDs: pins.map(canonical), taskOrder: canonicalOrders,
            chatSort: chatSort, projectSort: projectSort, grouping: legacy["mode"] as? String == "list" ? "list" : "project",
            pinnedSort: atoms["pinned-sidebar-sort-mode-v1"] as? String == "updated_at" ? "updated_at" : "manual",
            threadProjects: threadProjects, projectlessThreadIDs: projectless, threadWorkspaceRoots: roots)
    }
}

/// Read only the desktop fields required for sidebar presentation.
extension CodexDesktopSidebarSnapshot {
    static func read(codexHome: URL) throws -> Self {
        let data = try Data(contentsOf: codexHome.appendingPathComponent(".codex-global-state.json"))
        return try parse(data, codexHome: codexHome.path)
    }
}

/// The controller polls only while visible. Metadata checks avoid parsing the
/// desktop's potentially large state file when it has not changed.
actor CodexDesktopSidebarReader {
    private struct Signature: Equatable {
        let path: String
        let modified: Date?
        let size: UInt64
        let inode: UInt64
    }
    private var signature: Signature?
    private var cached: CodexDesktopSidebarSnapshot?

    func read(codexHome: URL) throws -> CodexDesktopSidebarSnapshot {
        do {
            let source = codexHome.appendingPathComponent(".codex-global-state.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let current = Signature(path: source.path, modified: attributes[.modificationDate] as? Date,
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            if current == signature, let cached { return cached }
            let snapshot = try CodexDesktopSidebarSnapshot.read(codexHome: codexHome)
            cached = snapshot; signature = current
            return snapshot
        } catch {
            cached = nil; signature = nil
            throw error
        }
    }
}

/// Recovers only image bytes already embedded in user messages. Paths in those
/// messages are association keys, never instructions to read arbitrary files.
enum CodexHistoryImageArchive {
    static func key(_ source: String) -> String {
        let normalized = URL(fileURLWithPath: source).standardizedFileURL.path
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func images(in line: Data) -> [(source: String, data: Data)] {
        guard line.count <= 70_000_000,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "response_item",
              let payload = record["payload"] as? [String: Any], payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else { return [] }
        // The runtime's numbered image tags supply an unambiguous ordered map.
        let texts = content.filter { $0["type"] as? String == "input_text" }.compactMap { $0["text"] as? String }
        let pattern = #"(?m)^<image name=\[Image #[0-9]+\] path="(/[^"]+)">"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var paths: [String] = []
        for text in texts {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { paths.append(String(text[range])) }
            }
        }
        let images = content.filter { $0["type"] as? String == "input_image" }
        guard !paths.isEmpty, paths.count == images.count, paths.count <= 40 else { return [] }
        return zip(paths, images).compactMap { path, image in
            guard let source = image["image_url"] as? String, source.hasPrefix("data:image/"),
                  source.utf8.count <= 66_000_000, let comma = source.firstIndex(of: ","),
                  source[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(source[source.index(after: comma)...])), data.count <= 49_000_000,
                  let decoded = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(decoded) > 0 else { return nil }
            return (path, data)
        }
    }

    static func recover(threadID: String, codexHome: URL, destination: URL) throws {
        guard UUID(uuidString: threadID) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let thread = threadID.lowercased()
        var rollouts = Set<URL>()
        try Task.checkCancellation()
        for folder in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(folder).resolvingSymlinksInPath()
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in entries {
                try Task.checkCancellation()
                var name = file.lastPathComponent.lowercased()
                if name.hasSuffix(".zst") { name = String(name.dropLast(4)) }
                guard name.hasSuffix(".jsonl") else { continue }
                name = String(name.dropLast(6))
                // Desktop continuations use threadID_sessionID. The first
                // rollout alone can predate months of messages and attachments.
                let exact = name.hasSuffix("-\(thread)")
                let continuation = name.range(of: "-\(thread)_").map {
                    UUID(uuidString: String(name[$0.upperBound...])) != nil
                } ?? false
                let resolved = file.resolvingSymlinksInPath()
                guard exact || continuation, resolved.path.hasPrefix(root.path + "/"),
                      (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                rollouts.insert(resolved)
            }
        }
        guard !rollouts.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var readBytes = 0, exportedBytes = 0, matched = false
        for rollout in rollouts.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            try Task.checkCancellation()
            if try recoverRollout(rollout, threadID: thread, destination: destination,
                                  readBytes: &readBytes, exportedBytes: &exportedBytes) { matched = true }
        }
        guard matched else { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func recoverRollout(_ rollout: URL, threadID: String, destination: URL,
                                       readBytes: inout Int, exportedBytes: inout Int) throws -> Bool {
        let input: FileHandle
        var process: Process?
        if rollout.pathExtension == "zst" {
            guard let binary = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw CocoaError(.featureUnsupported) }
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: binary)
            child.arguments = ["-dc", "--", rollout.path]
            child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            try child.run(); input = pipe.fileHandleForReading; process = child
        } else { input = try FileHandle(forReadingFrom: rollout) }
        defer {
            try? input.close()
            if let process, process.isRunning { process.terminate() }
        }
        var buffer = Data(), verifiedSession = false
        func consume(_ line: Data) throws {
            try Task.checkCancellation()
            if !verifiedSession {
                guard line.count <= 1_000_000,
                      let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      record["type"] as? String == "session_meta",
                      let payload = record["payload"] as? [String: Any],
                      (payload["id"] as? String)?.lowercased() == threadID else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                verifiedSession = true
                return
            }
            for image in images(in: line) {
                exportedBytes += image.data.count
                guard exportedBytes <= 200_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let target = destination.appendingPathComponent(key(image.source) + ".image")
                if !FileManager.default.fileExists(atPath: target.path) { try image.data.write(to: target, options: .atomic) }
            }
        }
        while let chunk = try input.read(upToCount: 131_072), !chunk.isEmpty {
            try Task.checkCancellation()
            readBytes += chunk.count
            guard readBytes <= 512_000_000 else { throw CocoaError(.fileReadTooLarge) }
            // Search only newly read bytes; rescanning a growing base64 line
            // on every chunk makes large image recovery quadratic.
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 10) {
                guard buffer.count + newline - start <= 70_000_000 else { throw CocoaError(.fileReadTooLarge) }
                buffer.append(contentsOf: chunk[start..<newline])
                try consume(buffer)
                buffer.removeAll(keepingCapacity: true)
                start = chunk.index(after: newline)
            }
            buffer.append(contentsOf: chunk[start...])
            guard buffer.count <= (verifiedSession ? 70_000_000 : 1_000_000) else { throw CocoaError(.fileReadTooLarge) }
        }
        if !buffer.isEmpty { try consume(buffer) }
        if let process { process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) } }
        return verifiedSession
    }
}
