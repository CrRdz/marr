import Foundation
import MarrCore

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public enum OpenAIClientError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case emptyAnswer
    case outputTruncated

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "AI API URL is invalid."
        case .invalidResponse:
            "The AI provider returned an invalid response."
        case .apiError(let message):
            "AI provider error: \(message)"
        case .emptyAnswer:
            "The AI provider returned an empty answer."
        case .outputTruncated:
            "The AI provider stopped because the output limit was reached. Increase Maximum Output Tokens and retry."
        }
    }
}

public struct OpenAIClient: VisionAIClient {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    public func ask(
        request: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> String {
        let endpoint: URL?

        switch connection.apiFormat {
        case .openAIResponses:
            endpoint = apiEndpoint(from: connection.baseURL, finalPathComponents: ["responses"])
        case .anthropicMessages:
            endpoint = apiEndpoint(from: connection.baseURL, finalPathComponents: ["v1", "messages"])
        }

        guard let endpoint else { throw OpenAIClientError.invalidURL }

        switch connection.apiFormat {
        case .openAIResponses:
            return try await askOpenAIResponses(
                endpoint: endpoint,
                visionRequest: request,
                model: model,
                connection: connection
            )
        case .anthropicMessages:
            return try await askAnthropicMessages(
                endpoint: endpoint,
                visionRequest: request,
                model: model,
                connection: connection
            )
        }
    }

    private func askOpenAIResponses(
        endpoint: URL,
        visionRequest: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> String {
        let body = ResponsesRequest(
            model: model,
            input: openAIInputMessages(from: visionRequest),
            maxOutputTokens: connection.maximumOutputTokens
        )
        let (data, response) = try await performRequest(
            endpoint: endpoint,
            body: body,
            connection: connection
        )
        try validate(response: response, data: data)

        let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        if envelope.status == "incomplete" || envelope.incompleteDetails?.reason == "max_output_tokens" {
            throw OpenAIClientError.outputTruncated
        }

        let answer = envelope.output
            .flatMap(\.content)
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !answer.isEmpty else { throw OpenAIClientError.emptyAnswer }
        return answer
    }

    private func askAnthropicMessages(
        endpoint: URL,
        visionRequest: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> String {
        let body = AnthropicMessagesRequest(
            model: model,
            maxTokens: connection.maximumOutputTokens,
            system: visionRequest.systemPrompt,
            messages: anthropicMessages(from: visionRequest)
        )
        let (data, response) = try await performRequest(
            endpoint: endpoint,
            body: body,
            connection: connection,
            additionalHeaders: ["anthropic-version": "2023-06-01"]
        )
        try validate(response: response, data: data)

        let envelope = try JSONDecoder().decode(AnthropicMessagesEnvelope.self, from: data)
        if envelope.stopReason == "max_tokens" {
            throw OpenAIClientError.outputTruncated
        }

        let answer = envelope.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !answer.isEmpty else { throw OpenAIClientError.emptyAnswer }
        return answer
    }

    private func performRequest<Body: Encodable>(
        endpoint: URL,
        body: Body,
        connection: InferenceConnection,
        additionalHeaders: [String: String] = [:]
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        applyAuthentication(connection, to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await transport.data(for: request)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenAIClientError.apiError(
                extractErrorMessage(from: data) ?? "HTTP \(response.statusCode)"
            )
        }
    }

    private func openAIInputMessages(from request: VisionRequest) -> [ResponsesRequest.InputMessage] {
        var messages = [
            ResponsesRequest.InputMessage(
                role: "system",
                content: [.init(type: "input_text", text: request.systemPrompt, imageURL: nil)]
            )
        ]
        messages.append(contentsOf: request.messages.map { message in
            ResponsesRequest.InputMessage(
                role: message.role.rawValue,
                content: message.content.map { content in
                    switch content {
                    case .text(let text):
                        .init(
                            type: message.role == .assistant ? "output_text" : "input_text",
                            text: text,
                            imageURL: nil
                        )
                    case .image(let image):
                        .init(
                            type: "input_image",
                            text: nil,
                            imageURL: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                        )
                    }
                }
            )
        })
        return messages
    }

    private func anthropicMessages(from request: VisionRequest) -> [AnthropicMessagesRequest.Message] {
        request.messages.map { message in
            AnthropicMessagesRequest.Message(
                role: message.role.rawValue,
                content: message.content.map { content in
                    switch content {
                    case .text(let text):
                        .init(type: "text", text: text, source: nil)
                    case .image(let image):
                        .init(
                            type: "image",
                            text: nil,
                            source: .init(
                                type: "base64",
                                mediaType: image.mimeType,
                                data: image.data.base64EncodedString()
                            )
                        )
                    }
                }
            )
        }
    }

    private func apiEndpoint(from baseURLString: String, finalPathComponents: [String]) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else {
            return nil
        }

        let existing = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let maximumOverlap = min(existing.count, finalPathComponents.count)
        let overlap = stride(from: maximumOverlap, through: 0, by: -1).first { count in
            count == 0 || Array(existing.suffix(count)) == Array(finalPathComponents.prefix(count))
        } ?? 0
        let completed = existing + finalPathComponents.dropFirst(overlap)
        components.path = "/" + completed.joined(separator: "/")
        return components.url
    }

    private func applyAuthentication(_ connection: InferenceConnection, to request: inout URLRequest) {
        let apiKey = connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            switch connection.authScheme {
            case .bearer:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .xAPIKey:
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            case .none:
                break
            }
        }
        for (name, value) in connection.customHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let error = dictionary["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return dictionary["message"] as? String ?? String(data: data, encoding: .utf8)
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let input: [InputMessage]
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, input
        case maxOutputTokens = "max_output_tokens"
    }

    struct InputMessage: Encodable {
        let role: String
        let content: [InputContent]
    }

    struct InputContent: Encodable {
        let type: String
        let text: String?
        let imageURL: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(imageURL, forKey: .imageURL)
        }
    }
}

private struct ResponsesEnvelope: Decodable {
    let status: String?
    let incompleteDetails: IncompleteDetails?
    let output: [Output]

    enum CodingKeys: String, CodingKey {
        case status, output
        case incompleteDetails = "incomplete_details"
    }

    struct IncompleteDetails: Decodable { let reason: String? }
    struct Output: Decodable { let content: [Content] }
    struct Content: Decodable {
        let type: String
        let text: String?
    }
}

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    struct Content: Encodable {
        let type: String
        let text: String?
        let source: ImageSource?
    }

    struct ImageSource: Encodable {
        let type: String
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }
}

private struct AnthropicMessagesEnvelope: Decodable {
    let content: [Content]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    struct Content: Decodable {
        let type: String
        let text: String?
    }
}
