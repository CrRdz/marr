import Foundation
import MarrCore
import Security

public struct InferenceSettingsSnapshot: Equatable, Sendable {
    public var provider: InferenceProvider
    public var openAIAPIKey: String
    public var gatewayBaseURL: String
    public var gatewayAPIKey: String
    public var gatewayAuthScheme: GatewayAuthScheme
    public var gatewayAPIFormat: GatewayAPIFormat
    public var customHeadersText: String
    public var model: String
    public var maximumOutputTokens: Int

    public init(
        provider: InferenceProvider,
        openAIAPIKey: String,
        gatewayBaseURL: String,
        gatewayAPIKey: String,
        gatewayAuthScheme: GatewayAuthScheme,
        gatewayAPIFormat: GatewayAPIFormat,
        customHeadersText: String,
        model: String,
        maximumOutputTokens: Int
    ) {
        self.provider = provider
        self.openAIAPIKey = openAIAPIKey
        self.gatewayBaseURL = gatewayBaseURL
        self.gatewayAPIKey = gatewayAPIKey
        self.gatewayAuthScheme = gatewayAuthScheme
        self.gatewayAPIFormat = gatewayAPIFormat
        self.customHeadersText = customHeadersText
        self.model = model
        self.maximumOutputTokens = min(max(256, maximumOutputTokens), 32_768)
    }

    public static let `default` = InferenceSettingsSnapshot(
        provider: .gateway,
        openAIAPIKey: "",
        gatewayBaseURL: "http://127.0.0.1:15721/claude-desktop",
        gatewayAPIKey: "",
        gatewayAuthScheme: .bearer,
        gatewayAPIFormat: .anthropicMessages,
        customHeadersText: "",
        model: "claude-sonnet-4-6",
        maximumOutputTokens: 4_096
    )
}

public protocol SettingsKeyValueStore: Sendable {
    func string(forKey key: String) -> String?
    func integer(forKey key: String) -> Int?
    func set(_ value: String, forKey key: String)
    func set(_ value: Int, forKey key: String)
}

public protocol SecretStore: Sendable {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
}

public final class UserDefaultsSettingsStore: SettingsKeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    public func integer(forKey key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    public func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
}

public struct KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.marr.Marr.inference") {
        self.service = service
    }

    public func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return value
    }

    public func set(_ value: String, for account: String) throws {
        let query = baseQuery(account: account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct KeychainError: LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
}

public final class InferenceSettingsRepository: @unchecked Sendable {
    private enum Key {
        static let provider = "inference.provider"
        static let gatewayBaseURL = "inference.gateway.baseURL"
        static let gatewayAuthScheme = "inference.gateway.authScheme"
        static let gatewayAPIFormat = "inference.gateway.apiFormat"
        static let model = "inference.model"
        static let maximumOutputTokens = "inference.maximumOutputTokens"
        static let openAIAPIKey = "openai-api-key"
        static let gatewayAPIKey = "gateway-api-key"
        static let customHeaders = "custom-headers"
    }

    private let values: any SettingsKeyValueStore
    private let secrets: any SecretStore

    public init(
        values: any SettingsKeyValueStore = UserDefaultsSettingsStore(),
        secrets: any SecretStore = KeychainSecretStore()
    ) {
        self.values = values
        self.secrets = secrets
    }

    public func load() throws -> InferenceSettingsSnapshot {
        let fallback = InferenceSettingsSnapshot.default
        return InferenceSettingsSnapshot(
            provider: values.string(forKey: Key.provider).flatMap(InferenceProvider.init(rawValue:)) ?? fallback.provider,
            openAIAPIKey: try secrets.string(for: Key.openAIAPIKey) ?? "",
            gatewayBaseURL: values.string(forKey: Key.gatewayBaseURL) ?? fallback.gatewayBaseURL,
            gatewayAPIKey: try secrets.string(for: Key.gatewayAPIKey) ?? "",
            gatewayAuthScheme: values.string(forKey: Key.gatewayAuthScheme).flatMap(GatewayAuthScheme.init(rawValue:)) ?? fallback.gatewayAuthScheme,
            gatewayAPIFormat: values.string(forKey: Key.gatewayAPIFormat).flatMap(GatewayAPIFormat.init(rawValue:)) ?? fallback.gatewayAPIFormat,
            customHeadersText: try secrets.string(for: Key.customHeaders) ?? "",
            model: values.string(forKey: Key.model) ?? fallback.model,
            maximumOutputTokens: values.integer(forKey: Key.maximumOutputTokens) ?? fallback.maximumOutputTokens
        )
    }

    public func save(_ settings: InferenceSettingsSnapshot) throws {
        values.set(settings.provider.rawValue, forKey: Key.provider)
        values.set(settings.gatewayBaseURL, forKey: Key.gatewayBaseURL)
        values.set(settings.gatewayAuthScheme.rawValue, forKey: Key.gatewayAuthScheme)
        values.set(settings.gatewayAPIFormat.rawValue, forKey: Key.gatewayAPIFormat)
        values.set(settings.model, forKey: Key.model)
        values.set(settings.maximumOutputTokens, forKey: Key.maximumOutputTokens)
        try secrets.set(settings.openAIAPIKey, for: Key.openAIAPIKey)
        try secrets.set(settings.gatewayAPIKey, for: Key.gatewayAPIKey)
        try secrets.set(settings.customHeadersText, for: Key.customHeaders)
    }
}
