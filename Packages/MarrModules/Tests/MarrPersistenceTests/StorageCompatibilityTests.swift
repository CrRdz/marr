import Foundation
import MarrCore
import Testing

struct StorageCompatibilityTests {
    @Test func existingSandboxRootWinsWithoutMovingDatabaseOrAttachments() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support")
        #expect(MarrStorage.resolveRoot(home: home, applicationSupport: support) == support.appendingPathComponent("Marr", isDirectory: true))
        let legacy = home.appendingPathComponent("Library/Containers/com.marr.Marr/Data/Library/Application Support/Marr", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let wal = legacy.appendingPathComponent("marr.sqlite-wal")
        try Data("existing WAL".utf8).write(to: wal)
        #expect(MarrStorage.resolveRoot(home: home, applicationSupport: support) == legacy)
        #expect(try Data(contentsOf: wal) == Data("existing WAL".utf8))
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Marr").path))
    }

    @Test func preferencesImportPreservesNewValuesAndDoesNotReplayDeletedKeys() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MarrMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let source = home.appendingPathComponent("Library/Containers/com.marr.Marr/Data/Library/Preferences/com.marr.Marr.plist")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let values: [String: Any] = ["model": "old", "codex.sync.enabled": true, "draft": Data([1, 2, 3])]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: source)
        defaults.set("new", forKey: "model")
        try MarrStorage.importLegacyPreferences(defaults: defaults, home: home)
        #expect(defaults.string(forKey: "model") == "new")
        #expect(defaults.bool(forKey: "codex.sync.enabled"))
        #expect(defaults.data(forKey: "draft") == Data([1, 2, 3]))
        defaults.removeObject(forKey: "draft")
        try MarrStorage.importLegacyPreferences(defaults: defaults, home: home)
        #expect(defaults.data(forKey: "draft") == nil)
        #expect(try Data(contentsOf: source) == data)
    }
}
