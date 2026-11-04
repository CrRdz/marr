import Foundation
import MarrCore
import Darwin
import Security

protocol ChatGPTCredentialStoring: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// One atomic Keychain item keeps rotated tokens and their expiry together.
final class ChatGPTKeychainStore: ChatGPTCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    deinit { if descriptor >= 0 { close(descriptor) } }

    // Only one local runtime may own these rotating tokens. The OS releases the
    // lock on process exit, including crashes; a second app instance fails safely.
    private func acquireOwnership() throws {
        try lock.withLock {
            if descriptor >= 0 { return }
            let root = MarrStorage.rootURL.appendingPathComponent("ChatGPT", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let path = root.appendingPathComponent("session.lock").path
            let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ChatGPTAuthError.message("Could not lock local ChatGPT credentials.") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw ChatGPTAuthError.message("ChatGPT credentials are in use by another Marr process. Close that instance and try again.")
            }
            descriptor = fd
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.marr.Marr.chatgpt.oauth.v1",
         kSecAttrAccount as String: "registrations"]
    }
    func load() throws -> Data? {
        try acquireOwnership()
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure(status) }
        return data
    }
    func save(_ data: Data) throws {
        try acquireOwnership()
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }
    private func failure(_ status: OSStatus) -> ChatGPTAuthError {
        .message("Could not access ChatGPT credentials in Keychain (\(status)).")
    }
}
