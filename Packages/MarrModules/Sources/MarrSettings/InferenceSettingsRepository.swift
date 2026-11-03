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
    public var chatGPTReasoningEffort: String
    public var chatGPTFastMode: Bool
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
    public var translationCodexModel: String
    public var translationCodexReasoningEffort: String

    public init(
        provider: InferenceProvider,
        openAIAPIKey: String,
        gatewayBaseURL: String,
        gatewayAPIKey: String,
        gatewayAuthScheme: GatewayAuthScheme,
        gatewayAPIFormat: GatewayAPIFormat,
        customHeadersText: String,
        model: String,
        chatGPTReasoningEffort: String = "",
        chatGPTFastMode: Bool = false,
        maximumOutputTokens: Int,
        translationUsesDedicatedConfiguration: Bool = false,
        translationProvider: TranslationProvider = .openAI,
        translationOpenAIAPIKey: String = "",
        translationGatewayBaseURL: String = "",
        translationGatewayAPIKey: String = "",
        translationGatewayAuthScheme: GatewayAuthScheme = .bearer,
        translationGatewayAPIFormat: GatewayAPIFormat = .openAIChatCompletions,
        translationCustomHeadersText: String = "",
        translationDeepLXServerURL: String = "http://127.0.0.1:1188",
        translationDeepLXAccessToken: String = "",
        translationModel: String = "gpt-4.1-mini",
        translationMaximumOutputTokens: Int = 4_096,
        translationCodexModel: String = "",
        translationCodexReasoningEffort: String = ""
    ) {
        self.provider = provider
        self.openAIAPIKey = openAIAPIKey
        self.gatewayBaseURL = gatewayBaseURL
        self.gatewayAPIKey = gatewayAPIKey
        self.gatewayAuthScheme = gatewayAuthScheme
        self.gatewayAPIFormat = gatewayAPIFormat
        self.customHeadersText = customHeadersText
        self.model = model
        self.chatGPTReasoningEffort = chatGPTReasoningEffort
        self.chatGPTFastMode = chatGPTFastMode
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
        self.translationCodexModel = translationCodexModel
        self.translationCodexReasoningEffort = translationCodexReasoningEffort
    }

    public static let `default` = InferenceSettingsSnapshot(
        provider: .chatGPT,
        openAIAPIKey: "",
        gatewayBaseURL: "http://127.0.0.1:15721/claude-desktop",
        gatewayAPIKey: "",
        gatewayAuthScheme: .bearer,
        gatewayAPIFormat: .anthropicMessages,
        customHeadersText: "",
        model: "",
        maximumOutputTokens: 4_096,
        translationUsesDedicatedConfiguration: false,
        translationProvider: .openAI,
        translationOpenAIAPIKey: "",
        translationGatewayBaseURL: "",
        translationGatewayAPIKey: "",
        translationGatewayAuthScheme: .bearer,
        translationGatewayAPIFormat: .openAIChatCompletions,
        translationCustomHeadersText: "",
        translationDeepLXServerURL: "http://127.0.0.1:1188",
        translationDeepLXAccessToken: "",
        translationModel: "gpt-4.1-mini",
        translationMaximumOutputTokens: 4_096,
        translationCodexModel: "",
        translationCodexReasoningEffort: ""
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

public enum InferenceCredential: CaseIterable, Hashable, Codable, Sendable {
    case connectionKey(String)
    case connectionHeaders(String)
    case providerAPIKey(GatewayPreset)
    case providerHeaders(GatewayPreset)

    public static var allCases: [Self] {
        [.openAIAPIKey, .gatewayAPIKey, .customHeaders, .translationOpenAIAPIKey,
         .translationGatewayAPIKey, .translationCustomHeaders, .translationDeepLXAccessToken]
        + GatewayPreset.allCases.filter { $0 != .custom && $0 != .ccSwitch }.flatMap { [.providerAPIKey($0), .providerHeaders($0)] }
    }
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
        static let chatGPTReasoningEffort = "inference.chatgpt.reasoningEffort"
        static let chatGPTFastMode = "inference.chatgpt.fastMode"
        static let maximumOutputTokens = "inference.maximumOutputTokens"
        static let translationUsesDedicatedConfiguration = "translation.usesDedicatedConfiguration"
        static let translationProvider = "translation.provider"
        static let translationGatewayBaseURL = "translation.gateway.baseURL"
        static let translationGatewayAuthScheme = "translation.gateway.authScheme"
        static let translationGatewayAPIFormat = "translation.gateway.apiFormat"
        static let translationModel = "translation.model"
        static let translationMaximumOutputTokens = "translation.maximumOutputTokens"
        static let translationDeepLXServerURL = "translation.deeplx.serverURL"
        static let translationCodexModel = "translation.codex.model"
        static let translationCodexReasoningEffort = "translation.codex.reasoningEffort"
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
            chatGPTReasoningEffort: configuration.chatGPTReasoningEffort,
            chatGPTFastMode: configuration.chatGPTFastMode,
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
            translationMaximumOutputTokens: configuration.translationMaximumOutputTokens,
            translationCodexModel: configuration.translationCodexModel,
            translationCodexReasoningEffort: configuration.translationCodexReasoningEffort
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
            chatGPTReasoningEffort: values.string(forKey: Key.chatGPTReasoningEffort) ?? fallback.chatGPTReasoningEffort,
            chatGPTFastMode: values.integer(forKey: Key.chatGPTFastMode) == 1,
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
            translationMaximumOutputTokens: values.integer(forKey: Key.translationMaximumOutputTokens) ?? fallback.translationMaximumOutputTokens,
            translationCodexModel: values.string(forKey: Key.translationCodexModel) ?? fallback.translationCodexModel,
            translationCodexReasoningEffort: values.string(forKey: Key.translationCodexReasoningEffort) ?? fallback.translationCodexReasoningEffort
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
        values.set(settings.chatGPTReasoningEffort, forKey: Key.chatGPTReasoningEffort)
        values.set(settings.chatGPTFastMode ? 1 : 0, forKey: Key.chatGPTFastMode)
        values.set(settings.maximumOutputTokens, forKey: Key.maximumOutputTokens)
        values.set(settings.translationUsesDedicatedConfiguration ? 1 : 0, forKey: Key.translationUsesDedicatedConfiguration)
        values.set(settings.translationProvider.rawValue, forKey: Key.translationProvider)
        values.set(settings.translationGatewayBaseURL, forKey: Key.translationGatewayBaseURL)
        values.set(settings.translationGatewayAuthScheme.rawValue, forKey: Key.translationGatewayAuthScheme)
        values.set(settings.translationGatewayAPIFormat.rawValue, forKey: Key.translationGatewayAPIFormat)
        values.set(settings.translationModel, forKey: Key.translationModel)
        values.set(settings.translationMaximumOutputTokens, forKey: Key.translationMaximumOutputTokens)
        values.set(settings.translationDeepLXServerURL, forKey: Key.translationDeepLXServerURL)
        values.set(settings.translationCodexModel, forKey: Key.translationCodexModel)
        values.set(settings.translationCodexReasoningEffort, forKey: Key.translationCodexReasoningEffort)
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

    public var selectedGatewayPreset: GatewayPreset {
        get { values.string(forKey: "gateway.preset").flatMap(GatewayPreset.init(rawValue:)) ?? .custom }
        set { values.set(newValue.rawValue, forKey: "gateway.preset") }
    }

    public var prefersAPIConversation: Bool {
        get { values.integer(forKey: "inference.prefersAPI") == 1 }
        set { values.set(newValue ? 1 : 0, forKey: "inference.prefersAPI") }
    }

    public func providerProfile(_ preset: GatewayPreset) -> ProviderConnectionProfile? {
        guard let text = values.string(forKey: "provider.profile." + preset.rawValue),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProviderConnectionProfile.self, from: data)
    }

    public func saveProviderProfile(_ profile: ProviderConnectionProfile, for preset: GatewayPreset) {
        guard let data = try? JSONEncoder().encode(profile), let text = String(data: data, encoding: .utf8) else { return }
        values.set(text, forKey: "provider.profile." + preset.rawValue)
    }

    public func loadAIConnections() -> AIConnectionRegistry {
        if let text = values.string(forKey: "ai.connections.v1"), let data = text.data(using: .utf8),
           let registry = try? JSONDecoder().decode(AIConnectionRegistry.self, from: data) { return registry }
        let old = loadConfiguration()
        var connections: [AIConnectionProfile] = []
        let openAI = AIConnectionProfile(id: "legacy.openai", name: "OpenAI API",
            baseURL: "https://api.openai.com/v1", apiFormat: .openAIResponses,
            models: old.provider == .openAI ? [old.model] : [],
            keyCredential: .openAIAPIKey, headersCredential: .connectionHeaders("legacy.openai"))
        if old.provider == .openAI || credentialIsStored(.openAIAPIKey) { connections.append(openAI) }
        for preset in GatewayPreset.allCases {
            let active = old.provider == .gateway && preset == selectedGatewayPreset
            let saved = providerProfile(preset)
            guard active || saved != nil else { continue }
            let profile = active ? ProviderConnectionProfile(baseURL: old.gatewayBaseURL,
                authScheme: old.gatewayAuthScheme, apiFormat: old.gatewayAPIFormat, model: old.model) : saved!
            connections.append(AIConnectionProfile(id: "legacy." + preset.rawValue, name: preset.title,
                preset: preset, baseURL: profile.baseURL, apiFormat: profile.apiFormat,
                authScheme: profile.authScheme, models: profile.model.isEmpty ? [] : [profile.model],
                keyCredential: [.custom, .ccSwitch].contains(preset) ? .gatewayAPIKey : .providerAPIKey(preset),
                headersCredential: [.custom, .ccSwitch].contains(preset) ? .customHeaders : .providerHeaders(preset)))
        }
        if old.provider == .chatGPT || old.translationProvider == .chatGPT {
            connections.append(.init(id: "legacy.chatgpt", name: "ChatGPT", kind: .chatGPT,
                                     models: old.provider == .chatGPT ? [old.model] : [old.translationModel]))
        }
        let activeID = old.provider == .openAI ? "legacy.openai" : old.provider == .chatGPT
            ? "legacy.chatgpt" : "legacy." + selectedGatewayPreset.rawValue
        var translation: AIModelReference?
        if old.translationUsesDedicatedConfiguration {
            let connection: AIConnectionProfile
            switch old.translationProvider {
            case .chatGPT:
                translation = .init(connectionID: "legacy.chatgpt", modelID: old.translationModel)
                connection = connections.first { $0.id == "legacy.chatgpt" }!
            case .deepLX:
                connection = .init(id: "legacy.translation", name: "DeepLX", kind: .deepLX,
                    baseURL: old.translationDeepLXServerURL, authScheme: .none,
                    keyCredential: .translationDeepLXAccessToken)
            case .openAI:
                connection = .init(id: "legacy.translation", name: "OpenAI · Translation",
                    baseURL: "https://api.openai.com/v1", apiFormat: .openAIResponses,
                    models: [old.translationModel], keyCredential: .translationOpenAIAPIKey)
            case .gateway:
                connection = .init(id: "legacy.translation", name: "Translation API",
                    baseURL: old.translationGatewayBaseURL, apiFormat: old.translationGatewayAPIFormat,
                    authScheme: old.translationGatewayAuthScheme, models: [old.translationModel],
                    keyCredential: .translationGatewayAPIKey, headersCredential: .translationCustomHeaders)
            }
            if translation == nil {
                connections.append(connection)
                translation = .init(connectionID: connection.id, modelID: old.translationModel)
            }
        }
        let registry = AIConnectionRegistry(connections: connections,
            conversation: .init(connectionID: activeID, modelID: old.model), translation: translation)
        saveAIConnections(registry)
        return registry
    }

    public func saveAIConnections(_ registry: AIConnectionRegistry) {
        guard let data = try? JSONEncoder().encode(registry), let text = String(data: data, encoding: .utf8) else { return }
        values.set(text, forKey: "ai.connections.v1")
    }

    private func account(for credential: InferenceCredential) -> String {
        switch credential {
        case .connectionKey(let id): "connection." + id + ".apiKey"
        case .connectionHeaders(let id): "connection." + id + ".headers"
        case .providerAPIKey(let preset): "provider." + preset.rawValue + ".apiKey"
        case .providerHeaders(let preset): "provider." + preset.rawValue + ".headers"
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
        case .connectionKey, .connectionHeaders, .providerAPIKey, .providerHeaders: account(for: credential) + ".configured"
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
