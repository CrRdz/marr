import Foundation
import MarrCore

public struct InferenceClient: VisionAIClient {
    private let transport: any HTTPTransport
    private let chatGPTSession: ChatGPTSession
    private let retrySleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        transport: any HTTPTransport = URLSession.shared,
        chatGPTSession: ChatGPTSession = .shared,
        retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.transport = transport
        self.chatGPTSession = chatGPTSession
        self.retrySleep = retrySleep
    }

    public func ask(
        request: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> String {
        try await askWithUsage(request: request, model: model, connection: connection).text
    }

    public func askStreaming(
        request: VisionRequest,
        model: String,
        connection: InferenceConnection,
        onEvent: @escaping VisionResponseHandler
    ) async throws -> VisionResponse {
        try Task.checkCancellation()
        do {
            let response = try await askStreamingResponse(
                request: request, model: model, connection: connection, onEvent: onEvent)
            try Task.checkCancellation()
            return response
        } catch {
            // URLSession can report a cancelled request as URLError.cancelled,
            // including before headers or while consuming the response body.
            // A transport error without task cancellation remains unchanged.
            try Task.checkCancellation()
            throw error
        }
    }

    private func askStreamingResponse(
        request: VisionRequest,
        model: String,
        connection: InferenceConnection,
        onEvent: @escaping VisionResponseHandler
    ) async throws -> VisionResponse {
        let usesPlan = connection.provider == .chatGPT
        var connection = connection
        if usesPlan {
            guard let profileID = connection.chatGPTProfileID else {
                throw ChatGPTAuthError.message("Choose a ChatGPT connection in Account settings.")
            }
            let token = try await chatGPTSession.accessToken(profileID: profileID)
            // Pin the destination and discard custom headers before attaching OAuth credentials.
            let timeout = connection.requestTimeout
            let reasoningEffort = connection.reasoningEffort
            let fastMode = connection.fastMode
            connection = .openAI(apiKey: token)
            connection.requestTimeout = timeout
            connection.reasoningEffort = reasoningEffort
            connection.fastMode = fastMode
        }
        let encoder = InferenceRequestEncoder()
        let (endpoint, encoded) = try encoder.encode(request: request, model: model, connection: connection)
        guard var body = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw InferenceClientError.invalidResponse
        }
        body["stream"] = true
        if usesPlan {
            body["store"] = false
            body.removeValue(forKey: "max_output_tokens")
            if let effort = connection.reasoningEffort, !effort.isEmpty {
                body["reasoning"] = ["effort": effort]
            }
            if connection.fastMode { body["service_tier"] = "fast" }
        }
        if connection.apiFormat == .openAIChatCompletions { body["stream_options"] = ["include_usage": true] }
        var retry = 0
        while true {
            try Task.checkCancellation()
            await onEvent(.requestStarted)
            let urlRequest = encoder.makeRequest(endpoint: endpoint,
                body: try JSONSerialization.data(withJSONObject: body), connection: connection, streaming: true)
            let requestTransport: any HTTPTransport = usesPlan && transport is URLSession
                ? URLSession(configuration: .ephemeral, delegate: ChatGPTNoRedirects(), delegateQueue: nil) : transport
            let (chunks, response) = try await requestTransport.stream(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw InferenceClientError.invalidResponse }
            if !(200..<300).contains(http.statusCode) {
                var errorBody = Data()
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    errorBody.append(chunk.prefix(max(0, 65_536 - errorBody.count)))
                    if errorBody.count >= 65_536 { break }
                }
                let message = InferenceResponseDecoder.extractErrorMessage(from: errorBody) ?? "HTTP \(http.statusCode)"
                // A rejected option is safe to remove; never resend a request accepted by the provider.
                let lower = message.lowercased()
                let unsupported = ["unsupported", "not supported", "unknown", "unrecognized", "not permitted", "extra inputs"].contains { lower.contains($0) }
                if !usesPlan, [400, 422].contains(http.statusCode), unsupported {
                    if body["stream_options"] != nil, lower.contains("stream_options") {
                        body.removeValue(forKey: "stream_options")
                        continue
                    }
                    if body["stream"] as? Bool == true, lower.contains("stream") {
                        body["stream"] = false
                        body.removeValue(forKey: "stream_options")
                        continue
                    }
                }
                let planError = usesPlan ? ChatGPTAPIError(data: errorBody, response: http) : nil
                if let planError, ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible"].contains(planError.code ?? "") {
                    throw planError
                }
                if let delay = InferenceRetryPolicy.delay(response: http, retry: retry) {
                    retry += 1
                    await onEvent(.retryScheduled(attempt: retry, resumeAt: Date().addingTimeInterval(delay)))
                    try await retrySleep(delay)
                    try Task.checkCancellation()
                    continue
                }
                if let planError { throw planError }
                throw InferenceClientError.apiError(message)
            }
            return try await InferenceResponseStream.consume(chunks, response: http, format: connection.apiFormat, requiresCompletedEvent: usesPlan, onEvent: onEvent)
        }
    }

    public func askWithUsage(
        request: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) async throws -> VisionResponse {
        if connection.provider == .chatGPT {
            return try await askStreaming(request: request, model: model, connection: connection, onEvent: { _ in })
        }
        try Task.checkCancellation()
        let encoder = InferenceRequestEncoder()
        let (endpoint, body) = try encoder.encode(request: request, model: model, connection: connection)
        let urlRequest = encoder.makeRequest(endpoint: endpoint, body: body, connection: connection)
        do {
            let (data, response) = try await transport.data(for: urlRequest)
            try Task.checkCancellation()
            try InferenceResponseDecoder.validate(response: response, data: data)
            return try InferenceResponseDecoder.decode(data, format: connection.apiFormat)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}
