import Foundation
import MarrCore
@testable import MarrNetworking
import Testing

@Suite("Chat Completions client")
struct ChatCompletionsClientTests {
    @Test("Nonstreaming Responses never treat an unfinished or failed status as a completed translation", arguments: [
        ("failed", InferenceClientError.apiError("The provider could not finish the response.")),
        ("in_progress", .incompleteStream), ("queued", .incompleteStream),
        ("cancelled", .incompleteStream), ("unknown_status", .incompleteStream),
        ("incomplete", .outputTruncated)
    ])
    func rejectsUnfinishedResponses(_ example: (String, InferenceClientError)) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": example.0,
            "output": [["content": [["type": "output_text", "text": "partial translation"]]]]
        ])
        let transport = ChatMockTransport(body: String(decoding: data, as: UTF8.self))
        var configuration = connection()
        configuration.apiFormat = .openAIResponses
        await #expect(throws: example.1) {
            try await InferenceClient(transport: transport).askWithUsage(
                request: sampleRequest, model: "model", connection: configuration)
        }
    }

    @Test("A Responses error object wins over nonempty output and preserves its message", arguments: ["failed", "completed"])
    func preservesResponsesFailure(status: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": status,
            "error": ["code": "server_error", "message": "  Provider unavailable\n"],
            "output": [["content": [["type": "output_text", "text": "partial translation"]]]]
        ])
        var configuration = connection()
        configuration.apiFormat = .openAIResponses
        await #expect(throws: InferenceClientError.apiError("Provider unavailable")) {
            try await InferenceClient(transport: ChatMockTransport(body: String(decoding: data, as: UTF8.self)))
                .ask(request: sampleRequest, model: "model", connection: configuration)
        }
    }

    @Test("Completed Responses and compatible responses without a status retain text and usage", arguments: [false, true])
    func acceptsCompletedAndStatuslessResponses(includesStatus: Bool) async throws {
        var object: [String: Any] = [
            "output": [["content": [["type": "output_text", "text": "  你好  "]]]],
            "usage": ["input_tokens": 7, "output_tokens": 2]
        ]
        if includesStatus { object["status"] = "completed" }
        let data = try JSONSerialization.data(withJSONObject: object)
        var configuration = connection()
        configuration.apiFormat = .openAIResponses
        let response = try await InferenceClient(transport: ChatMockTransport(body: String(decoding: data, as: UTF8.self)))
            .askWithUsage(request: sampleRequest, model: "model", connection: configuration)
        #expect(response.text == "你好")
        #expect(response.usage == .init(inputTokens: 7, outputTokens: 2))
    }

    @Test("URLSession-style cancellation is normalized for every provider and streaming mode", arguments: [
        GatewayAPIFormat.openAIResponses, .openAIChatCompletions, .anthropicMessages
    ], [false, true])
    func normalizesCancelledTransport(format: GatewayAPIFormat, streaming: Bool) async throws {
        let transport = CancellationCodeChatTransport(code: .cancelled, waitsForCancellation: true)
        var configuration = connection()
        configuration.apiFormat = format
        let task = Task {
            let client = InferenceClient(transport: transport)
            if streaming {
                return try await client.askStreaming(request: sampleRequest, model: "model",
                                                     connection: configuration, onEvent: { _ in })
            }
            return try await client.askWithUsage(request: sampleRequest, model: "model", connection: configuration)
        }
        await transport.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests == 1)
    }

    @Test("Transport failures keep their actual error when the calling task was not cancelled", arguments: [
        URLError.Code.cancelled, .timedOut, .networkConnectionLost
    ], [false, true])
    func preservesUncancelledTransportError(code: URLError.Code, streaming: Bool) async {
        let transport = CancellationCodeChatTransport(code: code, waitsForCancellation: false)
        let client = InferenceClient(transport: transport)
        await #expect(throws: URLError(code)) {
            if streaming {
                return try await client.askStreaming(request: sampleRequest, model: "model",
                                                     connection: connection(), onEvent: { _ in })
            }
            return try await client.askWithUsage(request: sampleRequest, model: "model", connection: connection())
        }
        #expect(await transport.requests == 1)
    }

    @Test("API format persists with a stable value")
    func apiFormatRoundTrip() throws {
        let data = try JSONEncoder().encode(GatewayAPIFormat.openAIChatCompletions)
        #expect(String(data: data, encoding: .utf8) == #""OpenAI Chat Completions""#)
        #expect(try JSONDecoder().decode(GatewayAPIFormat.self, from: data) == .openAIChatCompletions)
    }

    @Test("Base and complete endpoints preserve gateway paths and queries", arguments: [
        ("https://example.com", "https://example.com/v1/chat/completions"),
        (" https://example.com/ \n", "https://example.com/v1/chat/completions"),
        ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
        ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions"),
        ("https://example.com/chat/completions/", "https://example.com/chat/completions"),
        ("https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions"),
        ("https://example.com/proxy/team/v1", "https://example.com/proxy/team/v1/chat/completions"),
        ("https://example.com/api/chat", "https://example.com/api/chat/completions"),
        ("https://example.com/api", "https://example.com/api/chat/completions"),
        ("https://example.com/api/chat/completions?api-version=1", "https://example.com/api/chat/completions?api-version=1"),
        ("https://example.com?route=translation", "https://example.com/v1/chat/completions?route=translation")
    ])
    func completesEndpoints(_ example: (String, String)) async throws {
        let transport = ChatMockTransport(body: successBody)
        _ = try await InferenceClient(transport: transport).ask(
            request: sampleRequest,
            model: "translator",
            connection: connection(baseURL: example.0)
        )
        #expect(try #require(await transport.lastRequest).url?.absoluteString == example.1)
    }

    @Test("Text conversations use messages with configured headers and token limit")
    func encodesTextConversation() async throws {
        let transport = ChatMockTransport(body: successBody)
        var configuration = connection()
        configuration.apiKey = " token \n"
        configuration.authScheme = .bearer
        configuration.customHeaders = ["X-Translation-Route": "fast", "Authorization": "Bearer override"]
        configuration.maximumOutputTokens = 2_048
        configuration.requestTimeout = 25
        let conversation = VisionRequest(systemPrompt: "Translate precisely.", messages: [
            VisionMessage(role: .user, content: [.text("hello")]),
            VisionMessage(role: .assistant, content: [.text("你好")]),
            VisionMessage(role: .user, content: [.text("good"), .text("morning")])
        ])

        _ = try await InferenceClient(transport: transport).ask(
            request: conversation,
            model: "custom-translator",
            connection: configuration
        )

        let request = try #require(await transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 25)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer override")
        #expect(request.value(forHTTPHeaderField: "X-Translation-Route") == "fast")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try bodyObject(request)
        #expect(body["model"] as? String == "custom-translator")
        #expect(body["max_tokens"] as? Int == 2_048)
        #expect(body["input"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(messages.compactMap { $0["content"] as? String } == ["Translate precisely.", "hello", "你好", "good\n\nmorning"])
    }

    @Test("Images use a nested image URL while text stays in order")
    func encodesImageConversation() async throws {
        let transport = ChatMockTransport(body: successBody)
        let image = ConversationImageAsset(data: Data([1, 2, 3]), mimeType: "image/png", fileName: "capture.png")
        let request = VisionRequest(systemPrompt: "Read this.", messages: [
            VisionMessage(role: .user, content: [.text("Translate the screenshot"), .image(image)])
        ])
        _ = try await InferenceClient(transport: transport).ask(
            request: request,
            model: "vision-translator",
            connection: connection()
        )

        let body = try bodyObject(#require(await transport.lastRequest))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Translate the screenshot")
        #expect(content.last?["type"] as? String == "image_url")
        #expect((content.last?["image_url"] as? [String: String])?["url"] == "data:image/png;base64,AQID")
    }

    @Test("Text and PDF attachments retain their content")
    func encodesAttachments() async throws {
        let transport = ChatMockTransport(body: successBody)
        let text = ConversationImageAsset(data: Data("source".utf8), mimeType: "text/plain", fileName: "source.txt")
        let pdf = ConversationImageAsset(data: Data("%PDF".utf8), mimeType: "application/pdf", fileName: "report.pdf")
        let request = VisionRequest(systemPrompt: "Read this.", messages: [
            VisionMessage(role: .user, content: [.file(text), .file(pdf)])
        ])
        _ = try await InferenceClient(transport: transport).ask(
            request: request, model: "model", connection: connection()
        )

        let body = try bodyObject(#require(await transport.lastRequest))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "source.txt\nsource")
        #expect(content.last?["type"] as? String == "file")
        let file = try #require(content.last?["file"] as? [String: String])
        #expect(file["filename"] == "report.pdf")
        #expect(file["file_data"] == "data:application/pdf;base64,JVBERg==")
    }

    @Test("The first completion and its usage are returned")
    func decodesCompletionAndUsage() async throws {
        let transport = ChatMockTransport(body: #"{"choices":[{"message":{"content":"  你好\n","refusal":null},"finish_reason":"stop"},{"message":{"content":"alternative"},"finish_reason":"stop"}],"usage":{"prompt_tokens":25,"completion_tokens":10,"total_tokens":35}}"#)
        let response = try await InferenceClient(transport: transport).askWithUsage(
            request: sampleRequest, model: "model", connection: connection()
        )
        #expect(response.text == "你好")
        #expect(response.usage == InferenceTokenUsage(inputTokens: 25, outputTokens: 10))
    }

    @Test("Compatible gateway content arrays include only answer text")
    func decodesContentParts() async throws {
        let transport = ChatMockTransport(body: #"{"choices":[{"message":{"content":[{"type":"text","text":"first"},{"type":"reasoning","text":"private reasoning"},{"type":"text","text":"second"}]},"finish_reason":"stop"}]}"#)
        let response = try await InferenceClient(transport: transport).askWithUsage(
            request: sampleRequest, model: "model", connection: connection()
        )
        #expect(response.text == "first\n\nsecond")
        #expect(response.usage == nil)
    }

    @Test("Failures cannot be mistaken for completed translations", arguments: [
        (#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#, InferenceClientError.outputTruncated),
        (#"{"choices":[{"message":{"content":null,"refusal":"Cannot translate"},"finish_reason":"stop"}]}"#, .refused("Cannot translate")),
        (#"{"choices":[{"message":{"content":[{"type":"refusal","refusal":"Cannot translate"}]},"finish_reason":"stop"}]}"#, .refused("Cannot translate")),
        (#"{"choices":[{"message":{"content":"partial"},"finish_reason":"content_filter"}]}"#, .refused("The provider filtered the response.")),
        (#"{"choices":[{"message":{"content":" \n"},"finish_reason":"stop"}]}"#, .emptyAnswer),
        (#"{"choices":[]}"#, .emptyAnswer),
        (#"{"choices":[{"message":{"content":42}}]}"#, .invalidResponse),
        ("not JSON", .invalidResponse)
    ])
    func reportsResponseErrors(_ example: (String, InferenceClientError)) async throws {
        let client = InferenceClient(transport: ChatMockTransport(body: example.0))
        await #expect(throws: example.1) {
            try await client.ask(request: sampleRequest, model: "model", connection: connection())
        }
    }

    @Test("HTTP errors preserve the provider error message")
    func reportsHTTPError() async throws {
        let client = InferenceClient(transport: ChatMockTransport(
            statusCode: 429, body: #"{"error":{"message":"Rate limit exceeded"}}"#
        ))
        await #expect(throws: InferenceClientError.apiError("Rate limit exceeded")) {
            try await client.ask(request: sampleRequest, model: "model", connection: connection())
        }
    }

    @Test("A task cancelled before dispatch never starts an HTTP request")
    func preCancelledRequestDoesNotSend() async throws {
        let transport = ChatMockTransport(body: successBody)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await InferenceClient(transport: transport).ask(
                request: sampleRequest, model: "model", connection: connection()
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.lastRequest == nil)
    }

    @Test("Cancelling a translation propagates to the HTTP transport")
    func cancelsInFlightRequest() async throws {
        let transport = CancellableChatTransport()
        let task = Task {
            try await InferenceClient(transport: transport).ask(
                request: sampleRequest, model: "model", connection: connection()
            )
        }
        await transport.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.wasCancelled)
    }

    private var sampleRequest: VisionRequest {
        VisionRequest(systemPrompt: "Translate.", messages: [VisionMessage(role: .user, content: [.text("hello")])])
    }

    private var successBody: String {
        #"{"choices":[{"message":{"role":"assistant","content":"你好"},"finish_reason":"stop"}]}"#
    }

    private func connection(baseURL: String = "https://example.com/v1") -> InferenceConnection {
        InferenceConnection(
            provider: .gateway,
            baseURL: baseURL,
            apiKey: "",
            authScheme: .none,
            apiFormat: .openAIChatCompletions,
            customHeaders: [:]
        )
    }

    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor CancellationCodeChatTransport: HTTPTransport {
    private let code: URLError.Code
    private let waitsForCancellation: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requests = 0

    init(code: URLError.Code, waitsForCancellation: Bool) {
        self.code = code
        self.waitsForCancellation = waitsForCancellation
    }

    func waitUntilStarted() async {
        if requests > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        waiter?.resume()
        waiter = nil
        if waitsForCancellation {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { throw URLError(code) }
        }
        throw URLError(code)
    }
}

private actor ChatMockTransport: HTTPTransport {
    private(set) var lastRequest: URLRequest?
    private let statusCode: Int
    private let body: Data

    init(statusCode: Int = 200, body: String) {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return (body, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
    }
}

private actor CancellableChatTransport: HTTPTransport {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            wasCancelled = Task.isCancelled
            throw error
        }
        throw InferenceClientError.invalidResponse
    }
}
