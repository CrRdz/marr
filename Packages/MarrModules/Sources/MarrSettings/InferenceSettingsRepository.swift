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
    public var translationUsesDedicatedConfiguration: Bool
    public var translationProvider: TranslationProvider
    public var translationOpenAIAPIKey: String
    public var translationGatewayBaseURL: String
    public var translationGatewayAPIKey: String
    public var translationGatewayAuthScheme: GatewayAuthScheme
    public var translationGatewayAPIFormat: GatewayAPIFormat
    public var translationCustomHeadersText: String
    public var translationDeepLXServerURL: String
    public var translationDeepLXAccessToken: String
    public var translationModel: String
    public var translationMaximumOutputTokens: Int

    public init(
        provider: InferenceProvider,
        openAIAPIKey: String,
        gatewayBaseURL: String,
        gatewayAPIKey: String,
        gatewayAuthScheme: GatewayAuthScheme,
        gatewayAPIFormat: GatewayAPIFormat,
        customHeadersText: String,
        model: String,
        maximumOutputTokens: Int,
        translationUsesDedicatedConfiguration: Bool = false,
        translationProvider: TranslationProvider = .openAI,
        translationOpenAIAPIKey: String = "",
        translationGatewayBaseURL: String = "",
        translationGatewayAPIKey: String = "",
        translationGatewayAuthScheme: GatewayAuthScheme = .bearer,
        translationGatewayAPIFormat: GatewayAPIFormat = .openAIResponses,
        translationCustomHeadersText: String = "",
        translationDeepLXServerURL: String = "http://127.0.0.1:1188",
        translationDeepLXAccessToken: String = "",
        translationModel: String = "gpt-4.1-mini",
        translationMaximumOutputTokens: Int = 4_096
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
        self.translationUsesDedicatedConfiguration = translationUsesDedicatedConfiguration
        self.translationProvider = translationProvider
        self.translationOpenAIAPIKey = translationOpenAIAPIKey
        self.translationGatewayBaseURL = translationGatewayBaseURL
        self.translationGatewayAPIKey = translationGatewayAPIKey
        self.translationGatewayAuthScheme = translationGatewayAuthScheme
        self.translationGatewayAPIFormat = translationGatewayAPIFormat
        self.translationCustomHeadersText = translationCustomHeadersText
        self.translationDeepLXServerURL = translationDeepLXServerURL
        self.translationDeepLXAccessToken = translationDeepLXAccessToken
        self.translationModel = translationModel
        self.translationMaximumOutputTokens = min(max(256, translationMaximumOutputTokens), 32_768)
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
        maximumOutputTokens: 4_096,
        translationUsesDedicatedConfiguration: false,
        translationProvider: .openAI,
        translationOpenAIAPIKey: "",
        translationGatewayBaseURL: "",
        translationGatewayAPIKey: "",
        translationGatewayAuthScheme: .bearer,
        translationGatewayAPIFormat: .openAIResponses,
        translationCustomHeadersText: "",
        translationDeepLXServerURL: "http://127.0.0.1:1188",
        translationDeepLXAccessToken: "",
        translationModel: "gpt-4.1-mini",
        translationMaximumOutputTokens: 4_096
    )
}

public struct InferenceSecretsSnapshot: Equatable, Sendable {
    public var openAIAPIKey: String
    public var gatewayAPIKey: String
    public var customHeadersText: String
    public var translationOpenAIAPIKey: String
    public var translationGatewayAPIKey: String
    public var translationCustomHeadersText: String
    public var translationDeepLXAccessToken: String

    public init(
        openAIAPIKey: String,
        gatewayAPIKey: String,
        customHeadersText: String,
        translationOpenAIAPIKey: String = "",
        translationGatewayAPIKey: String = "",
        translationCustomHeadersText: String = "",
        translationDeepLXAccessToken: String = ""
    ) {
        self.openAIAPIKey = openAIAPIKey
        self.gatewayAPIKey = gatewayAPIKey
        self.customHeadersText = customHeadersText
        self.translationOpenAIAPIKey = translationOpenAIAPIKey
        self.translationGatewayAPIKey = translationGatewayAPIKey
        self.translationCustomHeadersText = translationCustomHeadersText
        self.translationDeepLXAccessToken = translationDeepLXAccessToken
    }

    public static let empty = InferenceSecretsSnapshot(
        openAIAPIKey: "",
        gatewayAPIKey: "",
        customHeadersText: "",
        translationOpenAIAPIKey: "",
        translationGatewayAPIKey: "",
        translationCustomHeadersText: "",
        translationDeepLXAccessToken: ""
    )
}

public enum InferenceCredential: CaseIterable, Hashable, Sendable {
    case openAIAPIKey
    case gatewayAPIKey
    case customHeaders
    case translationOpenAIAPIKey
    case translationGatewayAPIKey
    case translationCustomHeaders
    case translationDeepLXAccessToken
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

    public init(service: String = "com.marr.Marr.credentials.v2") {
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
        static let translationUsesDedicatedConfiguration = "translation.usesDedicatedConfiguration"
        static let translationProvider = "translation.provider"
        static let translationGatewayBaseURL = "translation.gateway.baseURL"
        static let translationGatewayAuthScheme = "translation.gateway.authScheme"
        static let translationGatewayAPIFormat = "translation.gateway.apiFormat"
        static let translationModel = "translation.model"
        static let translationMaximumOutputTokens = "translation.maximumOutputTokens"
        static let translationDeepLXServerURL = "translation.deeplx.serverURL"
        static let openAIAPIKey = "openai-api-key"
        static let gatewayAPIKey = "gateway-api-key"
        static let customHeaders = "custom-headers"
        static let translationOpenAIAPIKey = "translation-openai-api-key"
        static let translationGatewayAPIKey = "translation-gateway-api-key"
        static let translationCustomHeaders = "translation-custom-headers"
        static let translationDeepLXAccessToken = "translation-deeplx-access-token"
        static let openAIAPIKeyConfigured = "inference.credentials.v2.openAI.configured"
        static let gatewayAPIKeyConfigured = "inference.credentials.v2.gateway.configured"
        static let customHeadersConfigured = "inference.credentials.v2.customHeaders.configured"
        static let translationOpenAIAPIKeyConfigured = "translation.credentials.v1.openAI.configured"
        static let translationGatewayAPIKeyConfigured = "translation.credentials.v1.gateway.configured"
        static let translationCustomHeadersConfigured = "translation.credentials.v1.customHeaders.configured"
        static let translationDeepLXAccessTokenConfigured = "translation.credentials.v1.deeplx.configured"
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
        let configuration = loadConfiguration()
        let secrets = try loadSecrets()
        return InferenceSettingsSnapshot(
            provider: configuration.provider,
            openAIAPIKey: secrets.openAIAPIKey,
            gatewayBaseURL: configuration.gatewayBaseURL,
            gatewayAPIKey: secrets.gatewayAPIKey,
            gatewayAuthScheme: configuration.gatewayAuthScheme,
            gatewayAPIFormat: configuration.gatewayAPIFormat,
            customHeadersText: secrets.customHeadersText,
            model: configuration.model,
            maximumOutputTokens: configuration.maximumOutputTokens,
            translationUsesDedicatedConfiguration: configuration.translationUsesDedicatedConfiguration,
            translationProvider: configuration.translationProvider,
            translationOpenAIAPIKey: secrets.translationOpenAIAPIKey,
            translationGatewayBaseURL: configuration.translationGatewayBaseURL,
            translationGatewayAPIKey: secrets.translationGatewayAPIKey,
            translationGatewayAuthScheme: configuration.translationGatewayAuthScheme,
            translationGatewayAPIFormat: configuration.translationGatewayAPIFormat,
            translationCustomHeadersText: secrets.translationCustomHeadersText,
            translationDeepLXServerURL: configuration.translationDeepLXServerURL,
            translationDeepLXAccessToken: secrets.translationDeepLXAccessToken,
            translationModel: configuration.translationModel,
            translationMaximumOutputTokens: configuration.translationMaximumOutputTokens
        )
    }

    public func loadConfiguration() -> InferenceSettingsSnapshot {
        let fallback = InferenceSettingsSnapshot.default
        return InferenceSettingsSnapshot(
            provider: values.string(forKey: Key.provider).flatMap(InferenceProvider.init(rawValue:)) ?? fallback.provider,
            openAIAPIKey: "",
            gatewayBaseURL: values.string(forKey: Key.gatewayBaseURL) ?? fallback.gatewayBaseURL,
            gatewayAPIKey: "",
            gatewayAuthScheme: values.string(forKey: Key.gatewayAuthScheme).flatMap(GatewayAuthScheme.init(rawValue:)) ?? fallback.gatewayAuthScheme,
            gatewayAPIFormat: values.string(forKey: Key.gatewayAPIFormat).flatMap(GatewayAPIFormat.init(rawValue:)) ?? fallback.gatewayAPIFormat,
            customHeadersText: "",
            model: values.string(forKey: Key.model) ?? fallback.model,
            maximumOutputTokens: values.integer(forKey: Key.maximumOutputTokens) ?? fallback.maximumOutputTokens,
            translationUsesDedicatedConfiguration: values.integer(forKey: Key.translationUsesDedicatedConfiguration) == 1,
            translationProvider: values.string(forKey: Key.translationProvider).flatMap(TranslationProvider.init(rawValue:)) ?? fallback.translationProvider,
            translationOpenAIAPIKey: "",
            translationGatewayBaseURL: values.string(forKey: Key.translationGatewayBaseURL) ?? fallback.translationGatewayBaseURL,
            translationGatewayAPIKey: "",
            translationGatewayAuthScheme: values.string(forKey: Key.translationGatewayAuthScheme).flatMap(GatewayAuthScheme.init(rawValue:)) ?? fallback.translationGatewayAuthScheme,
            translationGatewayAPIFormat: values.string(forKey: Key.translationGatewayAPIFormat).flatMap(GatewayAPIFormat.init(rawValue:)) ?? fallback.translationGatewayAPIFormat,
            translationCustomHeadersText: "",
            translationDeepLXServerURL: values.string(forKey: Key.translationDeepLXServerURL) ?? fallback.translationDeepLXServerURL,
            translationDeepLXAccessToken: "",
            translationModel: values.string(forKey: Key.translationModel) ?? fallback.translationModel,
            translationMaximumOutputTokens: values.integer(forKey: Key.translationMaximumOutputTokens) ?? fallback.translationMaximumOutputTokens
        )
    }

    public func loadSecrets() throws -> InferenceSecretsSnapshot {
        InferenceSecretsSnapshot(
            openAIAPIKey: try credential(.openAIAPIKey) ?? "",
            gatewayAPIKey: try credential(.gatewayAPIKey) ?? "",
            customHeadersText: try credential(.customHeaders) ?? "",
            translationOpenAIAPIKey: try credential(.translationOpenAIAPIKey) ?? "",
            translationGatewayAPIKey: try credential(.translationGatewayAPIKey) ?? "",
            translationCustomHeadersText: try credential(.translationCustomHeaders) ?? "",
            translationDeepLXAccessToken: try credential(.translationDeepLXAccessToken) ?? ""
        )
    }

    public func credentialIsStored(_ credential: InferenceCredential) -> Bool {
        values.integer(forKey: configuredKey(for: credential)) == 1
    }

    public func credential(_ credential: InferenceCredential) throws -> String? {
        let value = try secrets.string(for: account(for: credential))
        values.set(value?.isEmpty == false ? 1 : 0, forKey: configuredKey(for: credential))
        return value
    }

    public func setCredential(_ value: String, for credential: InferenceCredential) throws {
        try secrets.set(value, for: account(for: credential))
        values.set(value.isEmpty ? 0 : 1, forKey: configuredKey(for: credential))
    }

    public func save(_ settings: InferenceSettingsSnapshot) throws {
        saveConfiguration(settings)
        try saveSecrets(InferenceSecretsSnapshot(
            openAIAPIKey: settings.openAIAPIKey,
            gatewayAPIKey: settings.gatewayAPIKey,
            customHeadersText: settings.customHeadersText,
            translationOpenAIAPIKey: settings.translationOpenAIAPIKey,
            translationGatewayAPIKey: settings.translationGatewayAPIKey,
            translationCustomHeadersText: settings.translationCustomHeadersText,
            translationDeepLXAccessToken: settings.translationDeepLXAccessToken
        ))
    }

    public func saveConfiguration(_ settings: InferenceSettingsSnapshot) {
        values.set(settings.provider.rawValue, forKey: Key.provider)
        values.set(settings.gatewayBaseURL, forKey: Key.gatewayBaseURL)
        values.set(settings.gatewayAuthScheme.rawValue, forKey: Key.gatewayAuthScheme)
        values.set(settings.gatewayAPIFormat.rawValue, forKey: Key.gatewayAPIFormat)
        values.set(settings.model, forKey: Key.model)
        values.set(settings.maximumOutputTokens, forKey: Key.maximumOutputTokens)
        values.set(settings.translationUsesDedicatedConfiguration ? 1 : 0, forKey: Key.translationUsesDedicatedConfiguration)
        values.set(settings.translationProvider.rawValue, forKey: Key.translationProvider)
        values.set(settings.translationGatewayBaseURL, forKey: Key.translationGatewayBaseURL)
        values.set(settings.translationGatewayAuthScheme.rawValue, forKey: Key.translationGatewayAuthScheme)
        values.set(settings.translationGatewayAPIFormat.rawValue, forKey: Key.translationGatewayAPIFormat)
        values.set(settings.translationModel, forKey: Key.translationModel)
        values.set(settings.translationMaximumOutputTokens, forKey: Key.translationMaximumOutputTokens)
        values.set(settings.translationDeepLXServerURL, forKey: Key.translationDeepLXServerURL)
    }

    public func saveSecrets(_ settings: InferenceSecretsSnapshot) throws {
        try setCredential(settings.openAIAPIKey, for: .openAIAPIKey)
        try setCredential(settings.gatewayAPIKey, for: .gatewayAPIKey)
        try setCredential(settings.customHeadersText, for: .customHeaders)
        try setCredential(settings.translationOpenAIAPIKey, for: .translationOpenAIAPIKey)
        try setCredential(settings.translationGatewayAPIKey, for: .translationGatewayAPIKey)
        try setCredential(settings.translationCustomHeadersText, for: .translationCustomHeaders)
        try setCredential(settings.translationDeepLXAccessToken, for: .translationDeepLXAccessToken)
    }

    private func account(for credential: InferenceCredential) -> String {
        switch credential {
        case .openAIAPIKey:
            Key.openAIAPIKey
        case .gatewayAPIKey:
            Key.gatewayAPIKey
        case .customHeaders:
            Key.customHeaders
        case .translationOpenAIAPIKey:
            Key.translationOpenAIAPIKey
        case .translationGatewayAPIKey:
            Key.translationGatewayAPIKey
        case .translationCustomHeaders:
            Key.translationCustomHeaders
        case .translationDeepLXAccessToken:
            Key.translationDeepLXAccessToken
        }
    }

    private func configuredKey(for credential: InferenceCredential) -> String {
        switch credential {
        case .openAIAPIKey:
            Key.openAIAPIKeyConfigured
        case .gatewayAPIKey:
            Key.gatewayAPIKeyConfigured
        case .customHeaders:
            Key.customHeadersConfigured
        case .translationOpenAIAPIKey:
            Key.translationOpenAIAPIKeyConfigured
        case .translationGatewayAPIKey:
            Key.translationGatewayAPIKeyConfigured
        case .translationCustomHeaders:
            Key.translationCustomHeadersConfigured
        case .translationDeepLXAccessToken:
            Key.translationDeepLXAccessTokenConfigured
        }
    }
}
