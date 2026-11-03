import Foundation

/// Keep existing sandbox archives in place, including SQLite WAL/SHM and
/// absolute attachment references. Fresh installs use normal Application Support.
public enum MarrStorage {
    public static var rootURL: URL {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return resolveRoot(home: manager.homeDirectoryForCurrentUser, applicationSupport: support)
    }

    public static func resolveRoot(home: URL, applicationSupport: URL) -> URL {
        let legacy = home.appendingPathComponent("Library/Containers/com.marr.Marr/Data/Library/Application Support/Marr", isDirectory: true)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &directory), directory.boolValue {
            return legacy
        }
        return applicationSupport.appendingPathComponent("Marr", isDirectory: true)
    }

    /// Called before any production controller or settings repository exists.
    /// Import only missing keys and mark success, leaving the old plist intact.
    public static func importLegacyPreferences(defaults: UserDefaults = .standard,
                                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let marker = "marr.unsandboxed.preferences-imported.v1"
        guard !defaults.bool(forKey: marker) else { return }
        let source = home.appendingPathComponent("Library/Containers/com.marr.Marr/Data/Library/Preferences/com.marr.Marr.plist")
        if FileManager.default.fileExists(atPath: source.path) {
            let data = try Data(contentsOf: source)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            for (key, value) in values where key != marker && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
