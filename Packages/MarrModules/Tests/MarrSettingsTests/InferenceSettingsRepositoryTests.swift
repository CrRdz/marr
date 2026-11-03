import Foundation
import MarrCore
@testable import MarrSettings
import Testing

@Suite("Inference settings")
struct InferenceSettingsRepositoryTests {
    @Test("Connection migration preserves both routes without accessing secrets")
    func migratesConnectionRegistry() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        var old = InferenceSettingsSnapshot.default
        old.provider = .gateway
        old.gatewayBaseURL = "https://company.example/v1"
        old.model = "company-model"
        old.translationUsesDedicatedConfiguration = true
        old.translationProvider = .gateway
        old.translationGatewayBaseURL = "https://translate.example/v1"
        old.translationModel = "translation-model"
        repository.selectedGatewayPreset = .anthropic
        repository.saveConfiguration(old)
        let registry = repository.loadAIConnections()
        let conversation = try #require(registry.connection(registry.conversation.connectionID))
        #expect(conversation.baseURL == old.gatewayBaseURL)
        #expect(conversation.keyCredential == .providerAPIKey(.anthropic))
        #expect(registry.conversation.modelID == old.model)
        let translation = try #require(registry.translation)
        #expect(registry.connection(translation.connectionID)?.keyCredential == .translationGatewayAPIKey)
        #expect(registry.connection(translation.connectionID)?.baseURL == old.translationGatewayBaseURL)
        #expect(translation.modelID == old.translationModel)
        #expect(repository.loadAIConnections() == registry)
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)
    }

    @Test("Connections to the same service have isolated keys and model references")
    func independentConnections() throws {
        let values = MemoryValues()
        let repository = InferenceSettingsRepository(values: values, secrets: MemorySecrets())
        let personal = AIConnectionProfile(name: "Personal", preset: .anthropic, models: ["same-model"])
        let work = AIConnectionProfile(name: "Work", preset: .anthropic, models: ["same-model"])
        try repository.setCredential("personal-key", for: personal.keyCredential)
        try repository.setCredential("work-key", for: work.keyCredential)
        let registry = AIConnectionRegistry(connections: [personal, work],
            conversation: .init(connectionID: personal.id, modelID: "same-model"),
            translation: .init(connectionID: work.id, modelID: "same-model"))
        repository.saveAIConnections(registry)
        #expect(repository.loadAIConnections() == registry)
        try repository.setCredential("", for: personal.keyCredential)
        #expect(try repository.credential(work.keyCredential) == "work-key")
        #expect(!values.strings.values.contains { $0.contains("personal-key") || $0.contains("work-key") })
    }

    @Test("DeepLX migration preserves its token while follow mode ignores stale settings")
    func migratesTranslationModes() throws {
        for dedicated in [false, true] {
            let repository = InferenceSettingsRepository(values: MemoryValues(), secrets: MemorySecrets())
            var old = InferenceSettingsSnapshot.default
            old.translationUsesDedicatedConfiguration = dedicated
            old.translationProvider = .deepLX
            old.translationDeepLXServerURL = "http://localhost:1999"
            repository.saveConfiguration(old)
            let registry = repository.loadAIConnections()
            if dedicated {
                let selection = try #require(registry.translation)
                #expect(registry.connection(selection.connectionID)?.kind == .deepLX)
                #expect(registry.connection(selection.connectionID)?.keyCredential == .translationDeepLXAccessToken)
                #expect(registry.connection(selection.connectionID)?.baseURL == old.translationDeepLXServerURL)
            } else { #expect(registry.translation == nil) }
        }
    }

    @Test("Provider keys and headers stay isolated, including removal")
    func isolatesProviderSecrets() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        try repository.setCredential("legacy", for: .gatewayAPIKey)
        try repository.setCredential("claude-secret", for: .providerAPIKey(.anthropic))
        try repository.setCredential("gemini-secret", for: .providerAPIKey(.google))
        try repository.setCredential("X-Private: a", for: .providerHeaders(.anthropic))
        #expect(try repository.credential(.providerAPIKey(.google)) == "gemini-secret")
        #expect(try repository.credential(.providerHeaders(.google)) == nil)
        try repository.setCredential("", for: .providerAPIKey(.anthropic))
        #expect(!repository.credentialIsStored(.providerAPIKey(.anthropic)))
        #expect(try repository.credential(.providerAPIKey(.google)) == "gemini-secret")
        #expect(try repository.credential(.gatewayAPIKey) == "legacy")
        #expect(!values.strings.values.contains("gemini-secret"))
    }

    @Test("Provider selection and edited endpoint profiles survive repository reload")
    func restoresProviderProfiles() {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        let profile = ProviderConnectionProfile(baseURL: "https://proxy.example/v1", authScheme: .bearer,
                                                apiFormat: .anthropicMessages, model: "custom-model")
        repository.saveProviderProfile(profile, for: .anthropic)
        repository.selectedGatewayPreset = .anthropic
        repository.prefersAPIConversation = true
        let reloaded = InferenceSettingsRepository(values: values, secrets: secrets)
        #expect(reloaded.providerProfile(.anthropic) == profile)
        #expect(reloaded.providerProfile(.google) == nil)
        #expect(reloaded.selectedGatewayPreset == .anthropic)
        #expect(reloaded.prefersAPIConversation)
        #expect(secrets.readCount == 0)
        #expect(GatewayPreset.anthropic.authScheme == .xAPIKey)
        #expect(GatewayPreset.ollama.authScheme == .none)
        #expect(GatewayPreset.google.apiFormat == .openAIChatCompletions)
    }

    @Test("ChatGPT reasoning selection survives a settings reload")
    func persistsChatGPTReasoningEffort() {
        let values = MemoryValues()
        let repository = InferenceSettingsRepository(values: values, secrets: MemorySecrets())
        var configuration = InferenceSettingsSnapshot.default
        configuration.model = "gpt-6.1-sol"
        configuration.chatGPTReasoningEffort = "high"
        configuration.chatGPTFastMode = true
        repository.saveConfiguration(configuration)
        #expect(repository.loadConfiguration().chatGPTReasoningEffort == "high")
        #expect(repository.loadConfiguration().chatGPTFastMode)
        #expect(repository.loadConfiguration().model == "gpt-6.1-sol")
    }

    @Test("Older configurations follow the conversation model and automatic reasoning by default")
    func defaultsMissingCodexTranslationSelections() {
        let values = MemoryValues()
        values.strings["translation.model"] = "existing-api-model"
        values.strings["translation.provider"] = TranslationProvider.deepLX.rawValue
        values.integers["translation.usesDedicatedConfiguration"] = 1
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)

        let configuration = repository.loadConfiguration()

        #expect(configuration.translationCodexModel.isEmpty)
        #expect(configuration.translationCodexReasoningEffort.isEmpty)
        #expect(InferenceSettingsSnapshot.default.translationCodexModel.isEmpty)
        #expect(InferenceSettingsSnapshot.default.translationCodexReasoningEffort.isEmpty)
        #expect(configuration.translationModel == "existing-api-model")
        #expect(configuration.translationProvider == .deepLX)
        #expect(configuration.translationUsesDedicatedConfiguration)
        #expect(values.strings["translation.codex.model"] == nil)
        #expect(values.strings["translation.codex.reasoningEffort"] == nil)
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)
    }

    @Test("Codex translation selections and resetting to automatic survive configuration reload")
    func persistsCodexTranslationSelections() {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)

        for (model, effort) in [("translation-codex", "high"), ("translation-codex", ""), ("", "low"), ("", "")] {
            var expected = InferenceSettingsSnapshot.default
            expected.translationCodexModel = model
            expected.translationCodexReasoningEffort = effort
            repository.saveConfiguration(expected)

            let reloaded = InferenceSettingsRepository(values: values, secrets: secrets).loadConfiguration()
            #expect(reloaded == expected)
            #expect(values.strings["translation.codex.model"] == model)
            #expect(values.strings["translation.codex.reasoningEffort"] == effort)
        }
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)
    }

    @Test("Full settings load retains Codex translation selections alongside credentials")
    func fullLoadPreservesCodexTranslationSelections() throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        let expected = InferenceSettingsSnapshot(
            provider: .openAI,
            openAIAPIKey: "test-conversation-key",
            gatewayBaseURL: "https://gateway.example/v1",
            gatewayAPIKey: "",
            gatewayAuthScheme: .none,
            gatewayAPIFormat: .openAIChatCompletions,
            customHeadersText: "",
            model: "conversation-api-model",
            maximumOutputTokens: 4_096,
            translationOpenAIAPIKey: "test-translation-key",
            translationCodexModel: "translation-codex",
            translationCodexReasoningEffort: "medium"
        )

        try repository.save(expected)
        let reloaded = try InferenceSettingsRepository(values: values, secrets: secrets).load()

        #expect(reloaded == expected)
        #expect(values.strings.values.contains("test-conversation-key") == false)
        #expect(values.strings.values.contains("test-translation-key") == false)
    }

    @Test("Codex translation preferences coexist with each dedicated API configuration",
          arguments: [TranslationProvider.openAI, .gateway, .deepLX])
    func preservesCodexSelectionsAcrossDedicatedAPIToggle(_ provider: TranslationProvider) throws {
        let values = MemoryValues()
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: values, secrets: secrets)
        var expected = InferenceSettingsSnapshot.default
        expected.translationUsesDedicatedConfiguration = true
        expected.translationProvider = provider
        expected.translationGatewayBaseURL = "https://translation.example/v1"
        expected.translationGatewayAPIFormat = .openAIChatCompletions
        expected.translationGatewayAPIKey = "test-gateway-key"
        expected.translationDeepLXServerURL = "https://deeplx.example"
        expected.translationDeepLXAccessToken = "test-deeplx-token"
        expected.translationModel = "dedicated-api-model"
        expected.translationCodexModel = "independent-codex-model"
        expected.translationCodexReasoningEffort = "high"

        try repository.save(expected)
        #expect(try repository.load() == expected)

        var configuration = repository.loadConfiguration()
        configuration.translationUsesDedicatedConfiguration = false
        repository.saveConfiguration(configuration)
        expected.translationUsesDedicatedConfiguration = false

        let reloaded = try InferenceSettingsRepository(values: values, secrets: secrets).load()
        #expect(reloaded == expected)
    }

    @Test("New custom translation APIs default to Chat Completions without changing the fallback API")
    func defaultsTranslationToChatCompletions() {
        let secrets = MemorySecrets()
        let repository = InferenceSettingsRepository(values: MemoryValues(), secrets: secrets)

        let configuration = repository.loadConfiguration()

        #expect(configuration.translationGatewayAPIFormat == .openAIChatCompletions)
        #expect(configuration.translationUsesDedicatedConfiguration == false)
        #expect(configuration.gatewayAPIFormat == .anthropicMessages)
        #expect(secrets.readCount == 0)
        #expect(secrets.writeCount == 0)
    }

    @Test("Saved translation protocols retain their meaning after adding Chat Completions",
          arguments: [GatewayAPIFormat.openAIResponses, .anthropicMessages, .openAIChatCompletions])
    func preservesSavedTranslationProtocol(_ format: GatewayAPIFormat) {
        let values = MemoryValues()
        values.strings["translation.gateway.apiFormat"] = format.rawValue
        values.strings["translation.gateway.baseURL"] = "https://translation.example/custom/v1"
        values.strings["translation.provider"] = TranslationProvider.gateway.rawValue
        values.integers["translation.usesDedicatedConfiguration"] = 1
        let repository = InferenceSettingsRepository(values: values, secrets: MemorySecrets())

        let configuration = repository.loadConfiguration()

        #expect(configuration.translationGatewayAPIFormat == format)
        #expect(configuration.translationGatewayBaseURL == "https://translation.example/custom/v1")
        #expect(configuration.translationProvider == .gateway)
        #expect(configuration.translationUsesDedicatedConfiguration)
    }

    @Test("Custom translation endpoints and optional authentication survive reload")
    func persistsCustomTranslationEndpoint() {
        let values = MemoryValues()
        let repository = InferenceSettingsRepository(values: values, secrets: MemorySecrets())
        var settings = InferenceSettingsSnapshot.default
        settings.translationUsesDedicatedConfiguration = true
        settings.translationProvider = .gateway
        settings.translationGatewayBaseURL = "http://127.0.0.1:1234/v1/chat/completions"
        settings.translationGatewayAuthScheme = .none
        settings.translationGatewayAPIFormat = .openAIChatCompletions
        settings.translationModel = "local-translation-model"

        repository.saveConfiguration(settings)
        let reloaded = InferenceSettingsRepository(values: values, secrets: MemorySecrets()).loadConfiguration()

        #expect(reloaded == settings)
    }

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
