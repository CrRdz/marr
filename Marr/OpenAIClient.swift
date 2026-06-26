import Foundation

protocol VisionAIClient: Sendable {
    func ask(request: VisionRequest, model: String, connection: InferenceConnection) async throws -> String
}

enum OpenAIClientError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "OpenAI API URL is invalid."
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case .apiError(let message):
            return "OpenAI API error: \(message)"
        case .emptyAnswer:
            return "OpenAI returned an empty answer."
        }
    }
}

enum InferenceProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "OpenAI"
    case gateway = "Gateway"

    var id: String { rawValue }
}

enum GatewayAuthScheme: String, CaseIterable, Identifiable, Sendable {
    case bearer = "Bearer"
    case xAPIKey = "x-api-key"
    case none = "None"

    var id: String { rawValue }
}

enum GatewayAPIFormat: String, CaseIterable, Identifiable, Sendable {
    case openAIResponses = "OpenAI Responses"
    case anthropicMessages = "Anthropic Messages"

    var id: String { rawValue }
}

struct InferenceConnection: Sendable {
    var provider: InferenceProvider
    var baseURL: String
    var apiKey: String
    var authScheme: GatewayAuthScheme
    var apiFormat: GatewayAPIFormat
    var customHeaders: [String: String]

    static func openAI(apiKey: String) -> InferenceConnection {
        InferenceConnection(
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            apiKey: apiKey,
            authScheme: .bearer,
            apiFormat: .openAIResponses,
            customHeaders: [:]
        )
    }
}

struct OpenAIClient: VisionAIClient {
    func ask(request: VisionRequest, model: String, connection: InferenceConnection) async throws -> String {
        let endpoint: URL?

        switch connection.apiFormat {
        case .openAIResponses:
            endpoint = apiEndpoint(from: connection.baseURL, finalPathComponents: ["responses"])
        case .anthropicMessages:
            endpoint = apiEndpoint(from: connection.baseURL, finalPathComponents: ["v1", "messages"])
        }

        guard let endpoint else {
            throw OpenAIClientError.invalidURL
        }

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
        let requestBody = ResponsesRequest(
            model: model,
            input: openAIInputMessages(from: visionRequest)
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthentication(connection, to: &request)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.apiError(extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)")
        }

        if let answer = try extractAnswer(from: data), !answer.isEmpty {
            return answer
        }

        throw OpenAIClientError.emptyAnswer
    }

    private func askAnthropicMessages(
        endpoint: URL,
        visionRequest: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> String {
        let requestBody = AnthropicMessagesRequest(
            model: model,
            maxTokens: 1024,
            system: visionRequest.systemPrompt,
            messages: anthropicMessages(from: visionRequest)
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyAuthentication(connection, to: &request)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIClientError.apiError(extractErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)")
        }

        if let answer = try extractAnthropicAnswer(from: data), !answer.isEmpty {
            return answer
        }

        throw OpenAIClientError.emptyAnswer
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
                        return .init(
                            type: message.role == .assistant ? "output_text" : "input_text",
                            text: text,
                            imageURL: nil
                        )
                    case .image(let image):
                        let dataURL = "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                        return .init(type: "input_image", text: nil, imageURL: dataURL)
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
                        return .init(type: "text", text: text, source: nil)
                    case .image(let image):
                        return .init(
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
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }

        guard components.scheme != nil, components.host != nil else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let existingComponents = path.split(separator: "/").map(String.init)

        if !existingComponents.suffix(finalPathComponents.count).elementsEqual(finalPathComponents) {
            for component in finalPathComponents {
                components.path = appendingPathComponent(component, to: components.path)
            }
        }

        return components.url
    }

    private func appendingPathComponent(_ component: String, to path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/\(component)"
        }

        if path.hasSuffix("/") {
            return "\(path)\(component)"
        }

        return "\(path)/\(component)"
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

    private func extractAnswer(from data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data)
        var texts: [String] = []

        collectOutputText(from: object, into: &texts)

        let answer = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return answer.isEmpty ? nil : answer
    }

    private func extractAnthropicAnswer(from data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any], let content = dictionary["content"] as? [[String: Any]] else {
            return nil
        }

        let answer = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return answer.isEmpty ? nil : answer
    }

    private func collectOutputText(from value: Any, into texts: inout [String]) {
        if let dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "output_text", let text = dictionary["text"] as? String {
                texts.append(text)
            }

            for nestedValue in dictionary.values {
                collectOutputText(from: nestedValue, into: &texts)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectOutputText(from: item, into: &texts)
            }
        }
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let error = dictionary["error"] as? [String: Any]
        else {
            return String(data: data, encoding: .utf8)
        }

        return error["message"] as? String
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let input: [InputMessage]

    struct InputMessage: Encodable {
        let role: String
        let content: [InputContent]
    }

    struct InputContent: Encodable {
        let type: String
        let text: String?
        let imageURL: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
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

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
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
            case type
            case mediaType = "media_type"
            case data
        }
    }
}
