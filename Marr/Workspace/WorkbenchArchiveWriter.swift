import Foundation

struct WorkbenchArchive: Codable {
    var workspaces: [SavedWorkspace]
    var tasks: [SavedTask]
    var selectedWorkspaceID: UUID?
    var selectedTaskID: UUID?
}

final class WorkbenchArchiveWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.marr.workbench.persistence", qos: .utility)
    private let defaults: UserDefaults
    private let key: String
    private let archiveURL: URL?
    private var legacyData: Data?
    private let lock = NSLock()
    private var pending: WorkbenchArchive?
    private var preparedData: Data?
    private var commitScheduled = false
    private var writerScheduled = false
    private var writeCount = 0
    private var wroteOnMainThread = false
    private var encodedOnMainThread = false

    init(defaults: UserDefaults, key: String, archiveURL: URL?) {
        self.defaults = defaults
        self.key = key
        self.archiveURL = archiveURL
        legacyData = archiveURL == nil ? nil : defaults.data(forKey: key)
    }

    @MainActor func save(_ archive: WorkbenchArchive, wait: Bool) {
        lock.lock()
        // At most one snapshot waits behind the writer. A terminal snapshot
        // supersedes a queued partial snapshot; an older write cannot win later.
        pending = archive
        if !writerScheduled {
            writerScheduled = true
            queue.async { [self] in drain() }
        }
        lock.unlock()
        if wait { flush() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                writerScheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            // Encoding failure leaves the previous valid archive intact.
            var data = try? JSONEncoder().encode(snapshot)
            if let archiveURL, let encoded = data {
                do {
                    try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let legacyData {
                        let backup = archiveURL.appendingPathExtension("legacy-backup")
                        if !FileManager.default.fileExists(atPath: backup.path) {
                            try legacyData.write(to: backup, options: .atomic)
                        }
                    }
                    try encoded.write(to: archiveURL, options: .atomic)
                    legacyData = nil
                } catch {
                    // Do not remove or replace the legacy source unless a full
                    // file and its migration backup have been safely written.
                    data = nil
                }
            }
            lock.lock()
            encodedOnMainThread = encodedOnMainThread || Thread.isMainThread
            if let data { preparedData = data }
            let needsCommit = data != nil && !commitScheduled
            if needsCommit { commitScheduled = true }
            lock.unlock()
            if needsCommit {
                // Never synchronously wait for the UI actor from this queue.
                // A synchronous selection/flush may be waiting for encoding.
                DispatchQueue.main.async { [self] in commitPreparedData() }
            }
        }
    }

    @MainActor private func commitPreparedData() {
        lock.lock()
        let data = preparedData
        preparedData = nil
        commitScheduled = false
        lock.unlock()
        guard let data else { return }
        // No writer lock is held while notifying UserDefaults/SwiftUI observers.
        if archiveURL != nil {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
        } else { defaults.set(data, forKey: key) }
        lock.lock()
        writeCount += 1
        wroteOnMainThread = archiveURL == nil && Thread.isMainThread
        lock.unlock()
    }

    @MainActor func flush() {
        // The barrier waits for encoding/file IO, never for UI notifications.
        queue.sync {}
        commitPreparedData()
    }
    var diagnostics: (writes: Int, encodingOnMainThread: Bool, writesOnMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (writeCount, encodedOnMainThread, wroteOnMainThread)
    }
}
