import Foundation
@testable import MarrNetworking
import Testing

@Suite("DeepLX translation client")
struct DeepLXTranslationClientTests {
    @Test("Batch requests overlap, stay bounded, preserve order, and deduplicate exact text")
    func batchPreservesOrder() async throws {
        let transport = BatchTranslationTransport()
        let result = try await DeepLXTranslationClient(transport: transport).translateBatch(
            ["0", "1", "2", "3", "4", "1"], serverURL: "http://localhost:1188"
        )
        #expect(result == ["译0", "译1", "译2", "译3", "译4", "译1"])
        #expect(await transport.requests == 5)
        #expect(await transport.peak == 3)
    }

    @Test("Empty and cancelled batches never issue requests")
    func emptyAndCancelledBatch() async throws {
        let transport = BatchTranslationTransport()
        let client = DeepLXTranslationClient(transport: transport)
        #expect(try await client.translateBatch([], serverURL: "http://localhost:1188").isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.translateBatch(["0"], serverURL: "http://localhost:1188")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests == 0)
    }

    @Test("Batch errors are surfaced instead of returning partial translations")
    func batchError() async {
        let transport = DeepLXMockTransport(statusCode: 429, body: #"{"message":"too many requests"}"#)
        await #expect(throws: DeepLXTranslationClientError.apiError("too many requests")) {
            try await DeepLXTranslationClient(transport: transport).translateBatch(
                ["one", "two", "three", "four"], serverURL: "http://localhost:1188"
            )
        }
    }

    @Test("Posts the DeepLX JSON format and returns translated data")
    func translatesText() async throws {
        let transport = DeepLXMockTransport(
            statusCode: 200,
            body: #"{"code":200,"data":"你好","source_lang":"EN","target_lang":"ZH"}"#
        )
        let client = DeepLXTranslationClient(transport: transport)

        let result = try await client.translate(
            "Hello",
            serverURL: "http://127.0.0.1:1188/",
            accessToken: "secret"
        )

        #expect(result == "你好")
        let request = try #require(await transport.lastRequest)
        #expect(request.url?.absoluteString == "http://127.0.0.1:1188/translate")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["text"] == "Hello")
        #expect(json["source_lang"] == "auto")
        #expect(json["target_lang"] == "ZH")
    }

    @Test("Keeps an explicitly configured translate endpoint")
    func keepsTranslateEndpoint() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
        let client = DeepLXTranslationClient(transport: transport)

        _ = try await client.translate("Hello", serverURL: "https://example.com/dlx/translate")

        #expect(await transport.lastRequest?.url?.absoluteString == "https://example.com/dlx/translate")
    }

    @Test("Surfaces the server error message")
    func reportsServerError() async {
        let transport = DeepLXMockTransport(
            statusCode: 429,
            body: #"{"code":429,"message":"too many requests"}"#
        )
        let client = DeepLXTranslationClient(transport: transport)

        await #expect(throws: DeepLXTranslationClientError.apiError("too many requests")) {
            try await client.translate("Hello", serverURL: "http://localhost:1188")
        }
    }
}

private actor DeepLXMockTransport: HTTPTransport {
    private let statusCode: Int
    private let body: String
    private(set) var lastRequest: URLRequest?

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

private actor BatchTranslationTransport: HTTPTransport {
    private(set) var requests = 0
    private(set) var peak = 0
    private var active = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        let text = body["text"]!
        requests += 1
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        // First input finishes last, exercising response-to-input mapping.
        try await Task.sleep(for: .milliseconds(text == "0" ? 100 : 20))
        let data = try JSONSerialization.data(withJSONObject: ["data": "译" + text])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
