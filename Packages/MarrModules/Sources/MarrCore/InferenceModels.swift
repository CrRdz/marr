import Foundation

public struct ConversationImageAsset: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let data: Data
    public let mimeType: String
    public let fileName: String

    public init(id: UUID = UUID(), data: Data, mimeType: String, fileName: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
    }
}

public enum ConversationTurnStatus: String, Codable, Equatable, Sendable {
    case loading
    case completed
    case failed
}

public struct ConversationTurn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var question: String
    public let imageIDs: [UUID]
    public var answer: String
    public var errorMessage: String?
    public var status: ConversationTurnStatus
    public var showsAssistant: Bool

    public init(
        id: UUID,
        question: String,
        imageIDs: [UUID],
        answer: String,
        errorMessage: String?,
        status: ConversationTurnStatus,
        showsAssistant: Bool
    ) {
        self.id = id
        self.question = question
        self.imageIDs = imageIDs
        self.answer = answer
        self.errorMessage = errorMessage
        self.status = status
        self.showsAssistant = showsAssistant
    }

    public var isLoading: Bool { status == .loading }
}

public enum VisionMessageRole: String, Equatable, Sendable {
    case user
    case assistant
}

public enum VisionContent: Equatable, Sendable {
    case text(String)
    case image(ConversationImageAsset)
}

public struct VisionMessage: Equatable, Sendable {
    public let role: VisionMessageRole
    public let content: [VisionContent]

    public init(role: VisionMessageRole, content: [VisionContent]) {
        self.role = role
        self.content = content
    }
}

public struct VisionRequest: Equatable, Sendable {
    public let systemPrompt: String
    public let messages: [VisionMessage]

    public init(systemPrompt: String, messages: [VisionMessage]) {
        self.systemPrompt = systemPrompt
        self.messages = messages
    }
}

public protocol VisionAIClient: Sendable {
    func ask(request: VisionRequest, model: String, connection: InferenceConnection) async throws -> String
}

public enum InferenceProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAI = "OpenAI"
    case gateway = "Gateway"

    public var id: String { rawValue }
}

public enum GatewayAuthScheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case bearer = "Bearer"
    case xAPIKey = "x-api-key"
    case none = "None"

    public var id: String { rawValue }
}

public enum GatewayAPIFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAIResponses = "OpenAI Responses"
    case anthropicMessages = "Anthropic Messages"

    public var id: String { rawValue }
}

public struct InferenceConnection: Equatable, Sendable {
    public var provider: InferenceProvider
    public var baseURL: String
    public var apiKey: String
    public var authScheme: GatewayAuthScheme
    public var apiFormat: GatewayAPIFormat
    public var customHeaders: [String: String]
    public var maximumOutputTokens: Int

    public init(
        provider: InferenceProvider,
        baseURL: String,
        apiKey: String,
        authScheme: GatewayAuthScheme,
        apiFormat: GatewayAPIFormat,
        customHeaders: [String: String],
        maximumOutputTokens: Int = 4_096
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.authScheme = authScheme
        self.apiFormat = apiFormat
        self.customHeaders = customHeaders
        self.maximumOutputTokens = min(max(256, maximumOutputTokens), 32_768)
    }

    public static func openAI(apiKey: String, maximumOutputTokens: Int = 4_096) -> InferenceConnection {
        InferenceConnection(
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            apiKey: apiKey,
            authScheme: .bearer,
            apiFormat: .openAIResponses,
            customHeaders: [:],
            maximumOutputTokens: maximumOutputTokens
        )
    }
}
