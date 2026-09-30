import Foundation
import MarrCore
@testable import MarrSettings
import Testing

@Suite("Inference settings")
struct InferenceSettingsRepositoryTests {
    @Test("Configuration and secrets survive repository reload")
    func persistsCompleteSnapshot() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        let expected = InferenceSettingsSnapshot(
            provider: .openAI,
            openAIAPIKey: "openai-secret",
            gatewayBaseURL: "https://gateway.example/v1",
            gatewayAPIKey: "gateway-secret",
            gatewayAuthScheme: .xAPIKey,
            gatewayAPIFormat: .openAIResponses,
            customHeadersText: "X-Secret: value",
            model: "gpt-test",
            maximumOutputTokens: 8_192
        )

        try repository.save(expected)

        #expect(try repository.load() == expected)
        #expect(values.strings.values.contains("openai-secret") == false)
        #expect(values.strings.values.contains("gateway-secret") == false)
        #expect(values.strings.values.contains("X-Secret: value") == false)
    }

    @Test("Dedicated translation configuration and credentials survive reload")
    func persistsDedicatedTranslationConfiguration() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        let settings = InferenceSettingsSnapshot(
            provider: .openAI,
            openAIAPIKey: "chat-secret",
            gatewayBaseURL: "https://chat.example/v1",
            gatewayAPIKey: "",
            gatewayAuthScheme: .bearer,
            gatewayAPIFormat: .openAIResponses,
            customHeadersText: "",
            model: "gpt-chat",
            maximumOutputTokens: 4_096,
            translationUsesDedicatedConfiguration: true,
            translationProvider: .gateway,
            translationOpenAIAPIKey: "",
            translationGatewayBaseURL: "https://translate.example/v1",
            translationGatewayAPIKey: "translation-secret",
            translationGatewayAuthScheme: .xAPIKey,
            translationGatewayAPIFormat: .anthropicMessages,
            translationCustomHeadersText: "X-Translation: enabled",
            translationModel: "translation-model",
            translationMaximumOutputTokens: 2_048
        )

        try repository.save(settings)

        #expect(try repository.load() == settings)
        #expect(values.strings.values.contains("translation-secret") == false)
        #expect(values.strings.values.contains("X-Translation: enabled") == false)
        #expect(repository.loadConfiguration().translationOpenAIAPIKey.isEmpty)
        #expect(repository.loadConfiguration().translationGatewayAPIKey.isEmpty)
        #expect(repository.loadConfiguration().translationCustomHeadersText.isEmpty)

        var configuration = repository.loadConfiguration()
        configuration.translationModel = "updated-translation-model"
        repository.saveConfiguration(configuration)

        #expect(try repository.loadSecrets().translationGatewayAPIKey == "translation-secret")
        #expect(try repository.loadSecrets().translationCustomHeadersText == "X-Translation: enabled")
    }

    @Test("DeepLX can be selected as the dedicated translation provider")
    func persistsDeepLXTranslationProvider() {
        let values = MemoryValues()
        let repository = InferenceSettingsRepository(values: values, secrets: MemorySecrets())
        var settings = InferenceSettingsSnapshot.default
        settings.translationUsesDedicatedConfiguration = true
        settings.translationProvider = .deepLX
        settings.translationDeepLXServerURL = "http://127.0.0.1:1188"

        repository.saveConfiguration(settings)

        let loaded = repository.loadConfiguration()
        #expect(loaded.translationProvider == .deepLX)
        #expect(loaded.translationDeepLXServerURL == "http://127.0.0.1:1188")
    }

    @Test("DeepLX access token is isolated from the gateway credential")
    func isolatesDeepLXAccessToken() throws {
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: MemoryValues(), secrets: secrets)

        try repository.setCredential("gateway-secret", for: .translationGatewayAPIKey)
        try repository.setCredential("deeplx-secret", for: .translationDeepLXAccessToken)

        #expect(try repository.credential(.translationGatewayAPIKey) == "gateway-secret")
        #expect(try repository.credential(.translationDeepLXAccessToken) == "deeplx-secret")
        #expect(secrets.values["translation-gateway-api-key"] == "gateway-secret")
        #expect(secrets.values["translation-deeplx-access-token"] == "deeplx-secret")
    }

    @Test("Startup configuration load does not touch secrets")
    func loadConfigurationAvoidsSecretStore() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        let expected = InferenceSettingsSnapshot(
            provider: .openAI,
            openAIAPIKey: "openai-secret",
            gatewayBaseURL: "https://gateway.example/v1",
            gatewayAPIKey: "gateway-secret",
            gatewayAuthScheme: .xAPIKey,
            gatewayAPIFormat: .openAIResponses,
            customHeadersText: "X-Secret: value",
            model: "gpt-test",
            maximumOutputTokens: 8_192
        )

        try repository.save(expected)
        secrets.resetAccessCounts()

        let configuration = repository.loadConfiguration()

        #expect(configuration.provider == expected.provider)
        #expect(configuration.gatewayBaseURL == expected.gatewayBaseURL)
        #expect(configuration.gatewayAuthScheme == expected.gatewayAuthScheme)
        #expect(configuration.gatewayAPIFormat == expected.gatewayAPIFormat)
        #expect(configuration.model == expected.model)
        #expect(configuration.maximumOutputTokens == expected.maximumOutputTokens)
        #expect(configuration.openAIAPIKey.isEmpty)
        #expect(configuration.gatewayAPIKey.isEmpty)
        #expect(configuration.customHeadersText.isEmpty)
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)
    }

    @Test("Configuration-only save preserves existing secrets")
    func saveConfigurationAvoidsSecretStore() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        let original = InferenceSettingsSnapshot(
            provider: .openAI,
            openAIAPIKey: "openai-secret",
            gatewayBaseURL: "https://gateway.example/v1",
            gatewayAPIKey: "gateway-secret",
            gatewayAuthScheme: .xAPIKey,
            gatewayAPIFormat: .openAIResponses,
            customHeadersText: "X-Secret: value",
            model: "gpt-test",
            maximumOutputTokens: 8_192
        )

        try repository.save(original)
        secrets.resetAccessCounts()

        var configuration = original
        configuration.openAIAPIKey = ""
        configuration.gatewayAPIKey = ""
        configuration.customHeadersText = ""
        configuration.model = "gpt-next"
        repository.saveConfiguration(configuration)

        #expect(try repository.loadSecrets().openAIAPIKey == "openai-secret")
        #expect(try repository.loadSecrets().gatewayAPIKey == "gateway-secret")
        #expect(try repository.loadSecrets().customHeadersText == "X-Secret: value")
        #expect(secrets.writeCount == 0)
    }

    @Test("Credential status uses metadata without reading secret data")
    func credentialStatusDoesNotReadSecret() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(
            values: values,
            secrets: secrets
        )
        try repository.setCredential("openai-secret", for: .openAIAPIKey)
        secrets.resetAccessCounts()

        #expect(repository.credentialIsStored(.openAIAPIKey))
        #expect(repository.credentialIsStored(.gatewayAPIKey) == false)
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)
    }

    @Test("Untracked legacy credentials are not queried by status checks")
    func ignoresLegacyCredentialDuringStatusCheck() {
        let secrets = MemorySecrets()
        secrets.values["openai-api-key"] = "legacy-secret"
        let repository = InferenceSettingsRepository(
            values: MemoryValues(),
            secrets: secrets
        )

        #expect(repository.credentialIsStored(.openAIAPIKey) == false)
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)
    }

    @Test("Single credential operations leave other credentials untouched")
    func accessesCredentialsIndividually() throws {
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(
            values: MemoryValues(),
            secrets: secrets
        )
        try repository.saveSecrets(InferenceSecretsSnapshot(
            openAIAPIKey: "openai-secret",
            gatewayAPIKey: "gateway-secret",
            customHeadersText: "X-Secret: value"
        ))
        secrets.resetAccessCounts()

        #expect(try repository.credential(.openAIAPIKey) == "openai-secret")
        #expect(secrets.readAccounts == ["openai-api-key"])

        try repository.setCredential("new-openai-secret", for: .openAIAPIKey)
        #expect(secrets.writeAccounts == ["openai-api-key"])
        #expect(secrets.values["gateway-api-key"] == "gateway-secret")
        #expect(secrets.values["custom-headers"] == "X-Secret: value")
    }

    @Test("Output limit is clamped to the supported settings range")
    func clampsOutputLimit() {
        var low = InferenceSettingsSnapshot.default
        low.maximumOutputTokens = 1
        let normalizedLow = InferenceSettingsSnapshot(
            provider: low.provider,
            openAIAPIKey: low.openAIAPIKey,
            gatewayBaseURL: low.gatewayBaseURL,
            gatewayAPIKey: low.gatewayAPIKey,
            gatewayAuthScheme: low.gatewayAuthScheme,
            gatewayAPIFormat: low.gatewayAPIFormat,
            customHeadersText: low.customHeadersText,
            model: low.model,
            maximumOutputTokens: low.maximumOutputTokens
        )
        let high = InferenceSettingsSnapshot(
            provider: low.provider,
            openAIAPIKey: "",
            gatewayBaseURL: low.gatewayBaseURL,
            gatewayAPIKey: "",
            gatewayAuthScheme: low.gatewayAuthScheme,
            gatewayAPIFormat: low.gatewayAPIFormat,
            customHeadersText: "",
            model: low.model,
            maximumOutputTokens: 100_000
        )

        #expect(normalizedLow.maximumOutputTokens == 256)
        #expect(high.maximumOutputTokens == 32_768)
    }
}

private final class MemoryValues: SettingsKeyValueStore, @unchecked Sendable {
    var strings: [String: String] = [:]
    var integers: [String: Int] = [:]

    func string(forKey key: String) -> String? { strings[key] }
    func integer(forKey key: String) -> Int? { integers[key] }
    func set(_ value: String, forKey key: String) { strings[key] = value }
    func set(_ value: Int, forKey key: String) { integers[key] = value }
}

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var readCount = 0
    var writeCount = 0
    var readAccounts: [String] = []
    var writeAccounts: [String] = []

    func string(for account: String) throws -> String? {
        readCount += 1
        readAccounts.append(account)
        return values[account]
    }

    func set(_ value: String, for account: String) throws {
        writeCount += 1
        writeAccounts.append(account)
        if value.isEmpty {
            values.removeValue(forKey: account)
        } else {
            values[account] = value
        }
    }

    func resetAccessCounts() {
        readCount = 0
        writeCount = 0
        readAccounts = []
        writeAccounts = []
    }
}
