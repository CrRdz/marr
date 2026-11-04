import Foundation

/// Provider identity is separate from the wire protocol and the model ID.
public enum GatewayPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case anthropic, google, deepseek, openrouter, moonshotai, xai, ollama
    case ccSwitch
    case custom = "none"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .anthropic: "Anthropic · Claude"
        case .google: "Google · Gemini"
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter"
        case .moonshotai: "Moonshot · Kimi"
        case .xai: "xAI · Grok"
        case .ollama: "Ollama"
        case .ccSwitch: "CC Switch"
        case .custom: "Custom provider"
        }
    }
    public var iconName: String? {
        switch self {
        case .custom: nil
        case .ccSwitch: "anthropic"
        default: rawValue
        }
    }
    public var baseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek: "https://api.deepseek.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .moonshotai: "https://api.moonshot.ai/v1"
        case .xai: "https://api.x.ai/v1"
        case .ollama: "http://localhost:11434/v1"
        case .ccSwitch: "http://127.0.0.1:15721/claude-desktop"
        case .custom: ""
        }
    }
    public var apiFormat: GatewayAPIFormat {
        self == .anthropic || self == .ccSwitch ? .anthropicMessages : .openAIChatCompletions
    }
    public var authScheme: GatewayAuthScheme {
        switch self {
        case .anthropic: .xAPIKey
        case .ollama: .none
        default: .bearer
        }
    }
    /// Examples are editable; availability is determined by the user's provider account.
    public var models: [String] {
        switch self {
        case .anthropic, .ccSwitch: ["claude-sonnet-4-6", "claude-opus-4-6", "claude-haiku-4-5"]
        case .google: ["gemini-2.5-pro", "gemini-2.5-flash"]
        case .deepseek: ["deepseek-v4-pro", "deepseek-v4-flash"]
        case .openrouter: ["anthropic/claude-sonnet-4.6", "google/gemini-2.5-pro", "openai/gpt-4.1"]
        case .moonshotai: ["kimi-k2.6", "kimi-k2.5"]
        case .xai: ["grok-4.6", "grok-4.5"]
        case .ollama, .custom: []
        }
    }
}

public struct ProviderConnectionProfile: Codable, Equatable, Sendable {
    public var baseURL: String
    public var authScheme: GatewayAuthScheme
    public var apiFormat: GatewayAPIFormat
    public var model: String
    public init(baseURL: String, authScheme: GatewayAuthScheme, apiFormat: GatewayAPIFormat, model: String) {
        self.baseURL = baseURL
        self.authScheme = authScheme
        self.apiFormat = apiFormat
        self.model = model
    }
}
