import Foundation
import MarrCore

/// Owns wire-format encoding and HTTP configuration for every inference request.
struct InferenceRequestEncoder {
    func encode(request: VisionRequest, model: String, connection: InferenceConnection) throws -> (endpoint: URL, body: Data) {
        let endpoint: URL?
        let encoded: Data
        switch connection.apiFormat {
        case .openAIResponses:
            endpoint = apiEndpoint(from: connection.baseURL, finalPathComponents: ["responses"])
            encoded = try JSONEncoder().encode(ResponsesRequest(
                model: model, input: openAIInputMessages(from: request), maxOutputTokens: connection.maximumOutputTokens))
        case .openAIChatCompletions:
            endpoint = apiEndpoint(from: connection.baseURL, finalPathComponents: ["chat", "completions"], defaultBasePathComponents: ["v1"])
            encoded = try JSONEncoder().encode(ChatCompletionsRequest(
                model: model, messages: chatCompletionMessages(from: request), maxTokens: connection.maximumOutputTokens))
        case .anthropicMessages:
            endpoint = apiEndpoint(from: connection.baseURL, finalPathComponents: ["v1", "messages"])
            encoded = try JSONEncoder().encode(AnthropicMessagesRequest(
                model: model, maxTokens: connection.maximumOutputTokens, system: request.systemPrompt,
                messages: try anthropicMessages(from: request)))
        }
        guard let endpoint else {
            throw InferenceClientError.invalidURL
        }
        return (endpoint, encoded)
    }

    func makeRequest(endpoint: URL, body: Data, connection: InferenceConnection, streaming: Bool = false) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = connection.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streaming {
            request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        }
        if connection.apiFormat == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        applyAuthentication(connection, to: &request)
        request.httpBody = body
        return request
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
                            imageURL: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
                        )
                    case .file(let file):
                        .init(
                            type: "input_file",
                            fileData: "data:\(file.mimeType);base64,\(file.data.base64EncodedString())",
                            filename: file.fileName
                        )
                    }
                }
            )
        })
        return messages
    }

    private func chatCompletionMessages(from request: VisionRequest) -> [ChatCompletionsRequest.Message] {
        var messages = [ChatCompletionsRequest.Message(role: "system", content: .text(request.systemPrompt))]
        messages.append(contentsOf: request.messages.map { message in
            let parts: [ChatCompletionsRequest.Part] = message.content.map { content in
                switch content {
                case .text(let text):
                    return .init(type: "text", text: text)
                case .image(let image):
                    return .init(
                        type: "image_url",
                        imageURL: .init(url: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())")
                    )
                case .file(let file):
                    if let text = decodedText(from: file) {
                        return .init(type: "text", text: "\(file.fileName)\n\(text)")
                    }
                    return .init(
                        type: "file",
                        file: .init(
                            filename: file.fileName,
                            fileData: "data:\(file.mimeType);base64,\(file.data.base64EncodedString())"
                        )
                    )
                }
            }
            // Plain strings also work with gateways that only implement text messages.
            let content: ChatCompletionsRequest.Content = parts.allSatisfy { $0.type == "text" }
                ? .text(parts.compactMap(\.text).joined(separator: "\n\n"))
                : .parts(parts)
            return .init(role: message.role.rawValue, content: content)
        })
        return messages
    }

    private func anthropicMessages(
        from request: VisionRequest
    ) throws -> [AnthropicMessagesRequest.Message] {
        try request.messages.map { message in
            AnthropicMessagesRequest.Message(
                role: message.role.rawValue,
                content: try message.content.map { content in
                    switch content {
                    case .text(let text):
                        return AnthropicMessagesRequest.Content(
                            type: "text",
                            text: text,
                            source: nil
                        )
                    case .image(let image):
                        return AnthropicMessagesRequest.Content(
                            type: "image",
                            text: nil,
                            source: .init(
                                type: "base64",
                                mediaType: image.mimeType,
                                data: image.data.base64EncodedString()
                            )
                        )
                    case .file(let file):
                        if file.mimeType == "application/pdf" {
                            return .init(
                                type: "document",
                                text: nil,
                                source: .init(
                                    type: "base64",
                                    mediaType: file.mimeType,
                                    data: file.data.base64EncodedString()
                                ),
                                title: file.fileName
                            )
                        }

                        guard let text = decodedText(from: file) else {
                            throw InferenceClientError.unsupportedAttachment(
                                "The Anthropic Messages format only supports PDF and plain-text attachments. Use the OpenAI Responses format for \"\(file.fileName)\"."
                            )
                        }
                        return .init(
                            type: "document",
                            text: nil,
                            source: .init(
                                type: "text",
                                mediaType: "text/plain",
                                data: text
                            ),
                            title: file.fileName
                        )
                    }
                }
            )
        }
    }

    private func decodedText(from file: ConversationImageAsset) -> String? {
        guard
            file.mimeType.hasPrefix("text/")
                || [
                    "application/json",
                    "application/javascript",
                    "application/typescript",
                    "application/toml",
                    "application/yaml",
                    "application/x-yaml"
                ].contains(file.mimeType)
        else {
            return nil
        }

        return String(data: file.data, encoding: .utf8)
            ?? String(data: file.data, encoding: .utf16)
            ?? String(data: file.data, encoding: .isoLatin1)
    }

    private func apiEndpoint(
        from baseURLString: String,
        finalPathComponents: [String],
        defaultBasePathComponents: [String] = []
    ) -> URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else {
            return nil
        }

        var existing = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if existing.isEmpty {
            existing = defaultBasePathComponents
        }
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

}
