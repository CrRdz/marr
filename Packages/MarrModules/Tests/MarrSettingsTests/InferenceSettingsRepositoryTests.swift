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

    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
}
