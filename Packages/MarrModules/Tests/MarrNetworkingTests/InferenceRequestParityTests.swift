import Foundation
import MarrCore
@testable import MarrNetworking
import Testing

@Suite("Inference request parity")
struct InferenceRequestParityTests {
    @Test("Buffered and streaming requests preserve the same content, authentication and endpoint",
          arguments: GatewayAPIFormat.allCases)
    func requestParity(format: GatewayAPIFormat) async throws {
        let transport = RequestParityTransport(format: format)
        let client = InferenceClient(transport: transport)
        let request = VisionRequest(systemPrompt: "Keep the system instruction", messages: [
            .init(role: .user, content: [
                .text("Explain these attachments"),
                .image(.init(data: Data([1, 2, 3]), mimeType: "image/png", fileName: "capture.png")),
                .file(.init(data: Data("example".utf8), mimeType: "text/plain", fileName: "note.txt"))
            ]),
            .init(role: .assistant, content: [.text("Previous answer")]),
            .init(role: .user, content: [.text("Continue")])
        ])
        let connection = InferenceConnection(provider: .gateway,
            baseURL: "https://example.invalid/proxy/v1?region=test", apiKey: "test-key",
            authScheme: .bearer, apiFormat: format, customHeaders: ["X-Workspace": "test"],
            maximumOutputTokens: 1234, requestTimeout: 37)

        let buffered = try await client.askWithUsage(request: request, model: "test-model", connection: connection)
        let streamed = try await client.askStreaming(request: request, model: "test-model", connection: connection, onEvent: { _ in })
        #expect(buffered == streamed)
        let captured = await transport.requests
        #expect(captured.count == 2)
        let first = try #require(captured.first)
        let second = try #require(captured.last)
        #expect(first.url == second.url)
        #expect(first.url?.query == "region=test")
        #expect(first.httpMethod == "POST")
        #expect(second.httpMethod == first.httpMethod)
        #expect(first.timeoutInterval == 37)
        #expect(second.timeoutInterval == first.timeoutInterval)
        for header in ["Content-Type", "Authorization", "X-Workspace", "anthropic-version"] {
            #expect(first.value(forHTTPHeaderField: header) == second.value(forHTTPHeaderField: header))
        }
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(first.value(forHTTPHeaderField: "X-Workspace") == "test")
        #expect(second.value(forHTTPHeaderField: "Accept") == "text/event-stream, application/json")
        let firstData = try #require(first.httpBody)
        let secondData = try #require(second.httpBody)
        let firstBody = try #require(JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        var secondBody = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        #expect(secondBody.removeValue(forKey: "stream") as? Bool == true)
        if format == .openAIChatCompletions {
            let options = secondBody.removeValue(forKey: "stream_options") as? [String: Bool]
            #expect(options == ["include_usage": true])
        }
        #expect(NSDictionary(dictionary: firstBody).isEqual(to: secondBody))
    }
}

private actor RequestParityTransport: HTTPTransport {
    let format: GatewayAPIFormat
    private(set) var requests: [URLRequest] = []

    init(format: GatewayAPIFormat) { self.format = format }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body: String
        switch format {
        case .openAIResponses:
            body = #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"ok"}]}]}"#
        case .openAIChatCompletions:
            body = #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#
        case .anthropicMessages:
            body = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}
