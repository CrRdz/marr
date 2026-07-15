import Foundation
import MarrCore
@testable import MarrNetworking
import Testing

@Suite("OpenAI client")
struct OpenAIClientTests {
    @Test("Anthropic base URL keeps a single v1 path")
    func anthropicEndpointOverlap() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        )
        let client = OpenAIClient(transport: transport)

        _ = try await client.ask(
            request: sampleRequest,
            model: "model",
            connection: connection(baseURL: "https://example.com/v1")
        )

        let request = try #require(await transport.lastRequest)
        #expect(request.url?.path == "/v1/messages")
    }

    @Test("Configured output limit is encoded")
    func encodesMaximumOutputTokens() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        )
        let client = OpenAIClient(transport: transport)
        var configured = connection(baseURL: "https://example.com")
        configured.maximumOutputTokens = 8_192

        _ = try await client.ask(request: sampleRequest, model: "model", connection: configured)

        let request = try #require(await transport.lastRequest)
        let data = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["max_tokens"] as? Int == 8_192)
    }

    @Test("Output-limit stop reason is surfaced as an error")
    func reportsTruncatedAnthropicResponse() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#
        )
        let client = OpenAIClient(transport: transport)

        await #expect(throws: OpenAIClientError.outputTruncated) {
            try await client.ask(
                request: sampleRequest,
                model: "model",
                connection: connection(baseURL: "https://example.com")
            )
        }
    }

    @Test("OpenAI incomplete response is surfaced as an error")
    func reportsTruncatedOpenAIResponse() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#
        )
        let client = OpenAIClient(transport: transport)

        await #expect(throws: OpenAIClientError.outputTruncated) {
            try await client.ask(
                request: sampleRequest,
                model: "model",
                connection: InferenceConnection(
                    provider: .gateway,
                    baseURL: "https://example.com/v1",
                    apiKey: "",
                    authScheme: .none,
                    apiFormat: .openAIResponses,
                    customHeaders: [:]
                )
            )
        }
    }

    @Test("Complete Anthropic endpoint is not appended twice")
    func completeAnthropicEndpointOverlap() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        )
        let client = OpenAIClient(transport: transport)

        _ = try await client.ask(
            request: sampleRequest,
            model: "model",
            connection: connection(baseURL: "https://example.com/v1/messages/")
        )

        #expect(try #require(await transport.lastRequest).url?.path == "/v1/messages")
    }

    private var sampleRequest: VisionRequest {
        VisionRequest(
            systemPrompt: "system",
            messages: [VisionMessage(role: .user, content: [.text("hello")])]
        )
    }

    private func connection(baseURL: String) -> InferenceConnection {
        InferenceConnection(
            provider: .gateway,
            baseURL: baseURL,
            apiKey: "",
            authScheme: .none,
            apiFormat: .anthropicMessages,
            customHeaders: [:]
        )
    }
}

private actor MockTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?
    private let statusCode: Int
    private let body: Data

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}
