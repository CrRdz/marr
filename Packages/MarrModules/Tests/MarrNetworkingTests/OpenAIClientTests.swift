import Foundation
import MarrCore
@testable import MarrNetworking
import Testing

@Suite("OpenAI client")
struct OpenAIClientTests {
    @Test("OpenAI usage is returned with the response")
    func decodesOpenAIUsage() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":120,"output_tokens":30,"total_tokens":150}}"#
        )
        let response = try await OpenAIClient(transport: transport).askWithUsage(
            request: sampleRequest,
            model: "model",
            connection: openAIConnection(baseURL: "https://example.com/v1")
        )

        #expect(response.text == "ok")
        #expect(response.usage == InferenceTokenUsage(inputTokens: 120, outputTokens: 30))
    }

    @Test("Anthropic usage is returned with the response")
    func decodesAnthropicUsage() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":75,"cache_creation_input_tokens":10,"cache_read_input_tokens":15,"output_tokens":25}}"#
        )
        let response = try await OpenAIClient(transport: transport).askWithUsage(
            request: sampleRequest,
            model: "model",
            connection: connection(baseURL: "https://example.com")
        )

        #expect(response.text == "ok")
        #expect(response.usage == InferenceTokenUsage(inputTokens: 100, outputTokens: 25))
    }

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

    @Test("OpenAI Responses encodes document attachments as input_file")
    func openAIResponsesEncodesFileAttachment() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"ok"}]}]}"#
        )
        let client = OpenAIClient(transport: transport)
        let file = ConversationImageAsset(
            data: Data("%PDF".utf8),
            mimeType: "application/pdf",
            fileName: "report.pdf"
        )
        let request = VisionRequest(
            systemPrompt: "system",
            messages: [
                VisionMessage(role: .user, content: [.file(file), .text("Summarize")])
            ]
        )

        _ = try await client.ask(
            request: request,
            model: "model",
            connection: openAIConnection(baseURL: "https://example.com/v1")
        )

        let urlRequest = try #require(await transport.lastRequest)
        let body = try #require(urlRequest.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        let userMessage = try #require(input.last)
        let content = try #require(userMessage["content"] as? [[String: Any]])
        let fileContent = try #require(content.first { $0["type"] as? String == "input_file" })
        #expect(fileContent["filename"] as? String == "report.pdf")
        #expect(
            (fileContent["file_data"] as? String)?
                .hasPrefix("data:application/pdf;base64,") == true
        )
    }

    @Test("Anthropic Messages encodes PDF attachments as documents")
    func anthropicEncodesPDFAttachment() async throws {
        let transport = MockTransport(
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
        )
        let client = OpenAIClient(transport: transport)
        let file = ConversationImageAsset(
            data: Data("%PDF".utf8),
            mimeType: "application/pdf",
            fileName: "report.pdf"
        )
        let request = VisionRequest(
            systemPrompt: "system",
            messages: [VisionMessage(role: .user, content: [.file(file)])]
        )

        _ = try await client.ask(
            request: request,
            model: "model",
            connection: connection(baseURL: "https://example.com")
        )

        let urlRequest = try #require(await transport.lastRequest)
        let body = try #require(urlRequest.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let document = try #require(content.first)
        let source = try #require(document["source"] as? [String: Any])
        #expect(document["type"] as? String == "document")
        #expect(document["title"] as? String == "report.pdf")
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "application/pdf")
    }

    @Test("Anthropic Messages reports unsupported binary documents")
    func anthropicRejectsUnsupportedBinaryAttachment() async throws {
        let client = OpenAIClient(
            transport: MockTransport(
                statusCode: 200,
                body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
            )
        )
        let file = ConversationImageAsset(
            data: Data([0x50, 0x4B]),
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            fileName: "report.docx"
        )
        let request = VisionRequest(
            systemPrompt: "system",
            messages: [VisionMessage(role: .user, content: [.file(file)])]
        )

        await #expect(
            throws: OpenAIClientError.unsupportedAttachment(
                "The Anthropic Messages format only supports PDF and plain-text attachments. Use the OpenAI Responses format for \"report.docx\"."
            )
        ) {
            try await client.ask(
                request: request,
                model: "model",
                connection: connection(baseURL: "https://example.com")
            )
        }
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

    private func openAIConnection(baseURL: String) -> InferenceConnection {
        InferenceConnection(
            provider: .gateway,
            baseURL: baseURL,
            apiKey: "",
            authScheme: .none,
            apiFormat: .openAIResponses,
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
