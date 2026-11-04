import Foundation
import MarrCore

/// A saved connection owns authentication references, never credential values.
public struct AIConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case api, chatGPT, deepLX }
    public var id: String
    public var name: String
    public var kind: Kind
    public var preset: GatewayPreset?
    public var baseURL: String
    public var apiFormat: GatewayAPIFormat
    public var authScheme: GatewayAuthScheme
    public var models: [String]
    public var keyCredential: InferenceCredential
    public var headersCredential: InferenceCredential
    public var chatGPTProfileID: String?

    public init(id: String = UUID().uuidString, name: String, kind: Kind = .api,
                preset: GatewayPreset? = nil, baseURL: String = "",
                apiFormat: GatewayAPIFormat = .openAIChatCompletions,
                authScheme: GatewayAuthScheme = .bearer, models: [String] = [],
                keyCredential: InferenceCredential? = nil, headersCredential: InferenceCredential? = nil,
                chatGPTProfileID: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.preset = preset
        self.baseURL = baseURL; self.apiFormat = apiFormat; self.authScheme = authScheme
        self.models = models; self.chatGPTProfileID = chatGPTProfileID
        self.keyCredential = keyCredential ?? .connectionKey(id)
        self.headersCredential = headersCredential ?? .connectionHeaders(id)
    }
    public var supportsConversation: Bool { kind != .deepLX }
    public var iconName: String? { kind == .chatGPT ? "openai" : preset?.iconName }
}

public struct AIModelReference: Codable, Equatable, Sendable {
    public var connectionID: String
    public var modelID: String
    public init(connectionID: String, modelID: String) {
        self.connectionID = connectionID; self.modelID = modelID
    }
}

public struct AIConnectionRegistry: Codable, Equatable, Sendable {
    public var connections: [AIConnectionProfile]
    public var conversation: AIModelReference
    /// Nil follows the conversation selection. Codex remains a separate runtime integration.
    public var translation: AIModelReference?
    public init(connections: [AIConnectionProfile], conversation: AIModelReference,
                translation: AIModelReference? = nil) {
        self.connections = connections; self.conversation = conversation; self.translation = translation
    }
    public func connection(_ id: String) -> AIConnectionProfile? { connections.first { $0.id == id } }
}
