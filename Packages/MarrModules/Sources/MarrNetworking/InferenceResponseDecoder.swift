import Foundation
import MarrCore

enum InferenceResponseDecoder {
    static func decode(_ data: Data, format: GatewayAPIFormat) throws -> VisionResponse {
        switch format {
        case .openAIResponses: return try responses(data)
        case .openAIChatCompletions: return try chatCompletions(data)
        case .anthropicMessages: return try messages(data)
        }
    }

    static func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw InferenceClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw InferenceClientError.apiError(
                extractErrorMessage(from: data) ?? "HTTP \(response.statusCode)"
            )
        }
    }

    static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let error = dictionary["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return dictionary["message"] as? String ?? String(data: data, encoding: .utf8)
    }
    private static func chatCompletions(_ data: Data) throws -> VisionResponse {
        let envelope: ChatCompletionsEnvelope
        do {
            envelope = try JSONDecoder().decode(ChatCompletionsEnvelope.self, from: data)
        } catch {
            throw InferenceClientError.invalidResponse
        }
        guard let choice = envelope.choices.first else { throw InferenceClientError.emptyAnswer }
        if choice.finishReason == "length" {
            throw InferenceClientError.outputTruncated
        }
        if let refusal = choice.message.refusalText, !refusal.isEmpty {
            throw InferenceClientError.refused(refusal)
        }
        if choice.finishReason == "content_filter" {
            throw InferenceClientError.refused("The provider filtered the response.")
        }

        let answer = choice.message.content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else { throw InferenceClientError.emptyAnswer }
        return VisionResponse(
            text: answer,
            usage: envelope.usage.map {
                InferenceTokenUsage(inputTokens: $0.promptTokens, outputTokens: $0.completionTokens)
            }
        )
    }

    private static func responses(_ data: Data) throws -> VisionResponse {
        let envelope: ResponsesEnvelope
        do {
            envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: data)
        } catch {
            throw InferenceClientError.invalidResponse
        }
        if envelope.error != nil || envelope.status == "failed" {
            let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InferenceClientError.apiError(
                message.flatMap { $0.isEmpty ? nil : $0 } ?? "The provider could not finish the response."
            )
        }
        if envelope.status == "incomplete" || envelope.incompleteDetails?.reason == "max_output_tokens" {
            throw InferenceClientError.outputTruncated
        }
        // Compatible gateways may omit status. When present, it must declare
        // completion: partial output can also accompany queued/failed work.
        if let status = envelope.status, status != "completed" {
            throw InferenceClientError.incompleteStream
        }

        let answer = envelope.output
            .flatMap(\.content)
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !answer.isEmpty else { throw InferenceClientError.emptyAnswer }
        return VisionResponse(
            text: answer,
            usage: envelope.usage.map {
                InferenceTokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens)
            }
        )
    }

    private static func messages(_ data: Data) throws -> VisionResponse {
        let envelope = try JSONDecoder().decode(AnthropicMessagesEnvelope.self, from: data)
        if envelope.stopReason == "max_tokens" {
            throw InferenceClientError.outputTruncated
        }

        let answer = envelope.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        guard !answer.isEmpty else { throw InferenceClientError.emptyAnswer }
        return VisionResponse(
            text: answer,
            usage: envelope.usage.map {
                InferenceTokenUsage(
                    inputTokens: $0.inputTokens + $0.cacheCreationInputTokens + $0.cacheReadInputTokens,
                    outputTokens: $0.outputTokens
                )
            }
        )
    }

}
