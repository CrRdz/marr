import Foundation
@testable import MarrNetworking
import Testing

@Suite("DeepLX translation client")
struct DeepLXTranslationClientTests {
    @Test("Malformed successful responses are distinct from an empty translation", arguments: [
        "<html>gateway failure</html>", "null", "[]", "{}", #"{"data":null}"#,
        #"{"data":{"text":"你好"}}"#, #"{"code":"200","data":"你好"}"#
    ])
    func rejectsMalformedSuccess(body: String) async {
        let transport = DeepLXMockTransport(statusCode: 200, body: body)
        let client = DeepLXTranslationClient(transport: transport)
        for _ in 0..<2 {
            await #expect(throws: DeepLXTranslationClientError.invalidResponse) {
                try await client.translate("Hello", serverURL: "http://localhost:1188")
            }
        }
        #expect(await transport.requests == 2)
    }

    @Test("Valid but blank translations are never cached", arguments: ["", " \n\t "])
    func rejectsBlankSuccess(text: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["data": text])
        let transport = DeepLXMockTransport(statusCode: 200, body: String(decoding: data, as: UTF8.self))
        let client = DeepLXTranslationClient(transport: transport)
        for _ in 0..<2 {
            await #expect(throws: DeepLXTranslationClientError.emptyTranslation) {
                try await client.translate("Hello", serverURL: "http://localhost:1188")
            }
        }
        #expect(await transport.requests == 2)
    }

    @Test("Error envelopes retain diagnostics even when data has an error-specific shape", arguments: [200, 429, 503])
    func preservesErrorEnvelope(status: Int) async {
        let transport = DeepLXMockTransport(statusCode: status,
            body: #"{"code":429,"data":{"retry_after":60},"message":"too many requests"}"#)
        await #expect(throws: DeepLXTranslationClientError.apiError("too many requests")) {
            try await DeepLXTranslationClient(transport: transport).translate("Hello", serverURL: "http://localhost:1188")
        }
        #expect(await transport.requests == 1)
    }

    @Test("An invalid diagnostic field cannot turn a declared API failure into success")
    func malformedMessageDoesNotHideFailureCode() async {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"code":503,"data":"failure","message":{"detail":"offline"}}"#)
        await #expect(throws: DeepLXTranslationClientError.apiError("Code 503")) {
            try await DeepLXTranslationClient(transport: transport).translate("Hello", serverURL: "http://localhost:1188")
        }
    }

    @Test("Non-HTTP transport responses are rejected")
    func rejectsNonHTTPResponse() async {
        await #expect(throws: DeepLXTranslationClientError.invalidResponse) {
            try await DeepLXTranslationClient(transport: NonHTTPTranslationTransport())
                .translate("Hello", serverURL: "http://localhost:1188")
        }
    }

    @Test("HTTP failures without usable diagnostics retain their status and are not retried", arguments: [400, 401, 403, 404, 408, 429, 500, 502, 503])
    func preservesHTTPStatus(status: Int) async {
        let transport = DeepLXMockTransport(statusCode: status, body: #"{"message":" \n "}"#)
        await #expect(throws: DeepLXTranslationClientError.apiError("HTTP \(status)")) {
            try await DeepLXTranslationClient(transport: transport).translate("Hello", serverURL: "http://localhost:1188")
        }
        #expect(await transport.requests == 1)
    }

    @Test("Invalid server addresses never reach the transport", arguments: ["", "http://", "https:///translate", "ftp://example.com", "example.com"])
    func rejectsInvalidEndpoint(server: String) async {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
        let client = DeepLXTranslationClient(transport: transport)
        await #expect(throws: DeepLXTranslationClientError.invalidURL) {
            try await client.translate("Hello", serverURL: server)
        }
        #expect(await transport.requests == 0)
    }

    @Test("Transport timeouts retain the finite deadline, are not retried, and do not populate cache")
    func timeoutCanBeRetriedExplicitly() async throws {
        let transport = TranslationTimeoutTransport()
        let client = DeepLXTranslationClient(transport: transport)
        await #expect(throws: URLError(.timedOut)) {
            try await client.translate("Hello", serverURL: "http://localhost:1188")
        }
        #expect(await transport.requests == 1)
        #expect(await transport.deadlines == [30])
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188") == "你好")
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188") == "你好")
        #expect(await transport.requests == 2)
    }

    @Test("Cancelling one URLSession-style request is normalized and does not cancel its independent peer")
    func normalizesTransportCancellation() async throws {
        let transport = TranslationCancellationTransport()
        let client = DeepLXTranslationClient(transport: transport)
        let first = Task { try await client.translate("Hello", serverURL: "http://localhost:1188") }
        await transport.waitUntilStarted()
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188") == "你好")
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188") == "你好")
        #expect(await transport.requests == 2)
    }

    @Test("Clearing cache prevents already outstanding responses from repopulating it")
    func clearingInvalidatesOutstandingCacheWrites() async throws {
        let transport = CancellationIgnoringTranslationTransport()
        let client = DeepLXTranslationClient(transport: transport)
        let task = Task { try await client.translate("Hello", serverURL: "http://localhost:1188") }
        await transport.waitUntilStarted()
        await client.clearCache()
        await transport.finishFirstRequest()
        #expect(try await task.value == "你好")
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188") == "你好")
        #expect(await transport.requests == 2)
    }

    @Test("Entry count limits also bound retained request and response bytes", arguments: [true, false])
    func doesNotCacheOversizedPayloads(largeInput: Bool) async throws {
        let text = largeInput ? String(repeating: "x", count: 65_537) : "Hello"
        let translation = largeInput ? "你好" : String(repeating: "译", count: 22_000)
        let data = try JSONSerialization.data(withJSONObject: ["data": translation])
        let transport = DeepLXMockTransport(statusCode: 200, body: String(decoding: data, as: UTF8.self))
        let client = DeepLXTranslationClient(transport: transport)
        for _ in 0..<2 {
            #expect(try await client.translate(text, serverURL: "http://localhost:1188") == translation)
        }
        #expect(await transport.requests == 2)
    }

    @Test("A batch failure cancels its active peers and never schedules remaining spans")
    func failedBatchStopsScheduling() async {
        let transport = FailingBatchTranslationTransport()
        await #expect(throws: DeepLXTranslationClientError.apiError("unavailable")) {
            try await DeepLXTranslationClient(transport: transport).translateBatch(
                ["fail longest", "second", "third", "x"], serverURL: "http://localhost:1188")
        }
        #expect(await transport.requests == 3)
        #expect(await transport.cancelled == 2)
    }

    @Test("Recent exact translations reuse the resolved endpoint without another request")
    func reusesRecentTranslation() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
        let client = DeepLXTranslationClient(transport: transport)
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188/") == "你好")
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188/translate") == "你好")
        #expect(await transport.requests == 1)
        await client.clearCache()
        _ = try await client.translate("Hello", serverURL: "http://localhost:1188")
        #expect(await transport.requests == 2)
    }

    @Test("Connection probes bypass existing cache and do not populate new cache entries")
    func bypassesCacheForConnectionProbe() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
        let client = DeepLXTranslationClient(transport: transport)
        _ = try await client.translate("Hello", serverURL: "http://localhost:1188")
        _ = try await client.translate("Hello", serverURL: "http://localhost:1188", useCache: false)
        #expect(await transport.requests == 2)
        _ = try await client.translate("New probe", serverURL: "http://localhost:1188", useCache: false)
        _ = try await client.translate("New probe", serverURL: "http://localhost:1188")
        #expect(await transport.requests == 4)
    }

    @Test("Cache entries are isolated by exact text, source, target, server and credentials")
    func isolatesTranslationConfiguration() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
        let client = DeepLXTranslationClient(transport: transport)
        let configurations = [
            ("Hello", "auto", "ZH", "http://localhost:1188", "first"),
            ("Hello ", "auto", "ZH", "http://localhost:1188", "first"),
            ("Hello", "EN", "ZH", "http://localhost:1188", "first"),
            ("Hello", "auto", "JA", "http://localhost:1188", "first"),
            ("Hello", "auto", "ZH", "http://localhost:1188/other", "first"),
            ("Hello", "auto", "ZH", "http://localhost:1188", "second"),
        ]
        for (text, source, target, server, token) in configurations {
            _ = try await client.translate(
                text, sourceLanguage: source, targetLanguage: target,
                serverURL: server, accessToken: token
            )
        }
        #expect(await transport.requests == configurations.count)
        _ = try await client.translate("Hello", serverURL: "http://localhost:1188", accessToken: "first")
        #expect(await transport.requests == configurations.count)
    }

    @Test("The bounded cache evicts the least recently used result")
    func evictsLeastRecentlyUsedTranslation() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"translated"}"#)
        let client = DeepLXTranslationClient(transport: transport, cacheCapacity: 2)
        for text in ["A", "B", "A", "C", "A", "B"] {
            _ = try await client.translate(text, serverURL: "http://localhost:1188")
        }
        #expect(await transport.requests == 4)
    }

    @Test("Expired results are requested again")
    func expiresCachedTranslation() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
        let client = DeepLXTranslationClient(transport: transport, cacheLifetime: 0.01)
        _ = try await client.translate("Hello", serverURL: "http://localhost:1188")
        try await Task.sleep(for: .milliseconds(25))
        _ = try await client.translate("Hello", serverURL: "http://localhost:1188")
        #expect(await transport.requests == 2)
    }

    @Test("Caching can be disabled by capacity or lifetime")
    func disablesCaching() async throws {
        for (capacity, lifetime) in [(0, 300.0), (256, 0.0)] {
            let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
            let client = DeepLXTranslationClient(
                transport: transport, cacheCapacity: capacity, cacheLifetime: lifetime
            )
            for _ in 0..<2 {
                _ = try await client.translate("Hello", serverURL: "http://localhost:1188")
            }
            #expect(await transport.requests == 2)
        }
    }

    @Test("Server failures and empty responses are never cached")
    func doesNotCacheFailedTranslations() async {
        for (status, body, error) in [
            (429, #"{"message":"rate limited"}"#, DeepLXTranslationClientError.apiError("rate limited")),
            (200, #"{"code":429,"data":"not a translation","message":"rate limited"}"#, DeepLXTranslationClientError.apiError("rate limited")),
            (200, #"{"data":"  "}"#, DeepLXTranslationClientError.emptyTranslation),
        ] {
            let transport = DeepLXMockTransport(statusCode: status, body: body)
            let client = DeepLXTranslationClient(transport: transport)
            for _ in 0..<2 {
                await #expect(throws: error) {
                    try await client.translate("Hello", serverURL: "http://localhost:1188")
                }
            }
            #expect(await transport.requests == 2)
        }
    }

    @Test("Cancellation wins over a cached result")
    func cancelsCachedTranslation() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"你好"}"#)
        let client = DeepLXTranslationClient(transport: transport)
        _ = try await client.translate("Hello", serverURL: "http://localhost:1188")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.translate("Hello", serverURL: "http://localhost:1188")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests == 1)
    }

    @Test("A response arriving after cancellation is neither returned nor cached")
    func doesNotCacheCancelledTranslation() async throws {
        let transport = CancellationIgnoringTranslationTransport()
        let client = DeepLXTranslationClient(transport: transport)
        let task = Task {
            try await client.translate("Hello", serverURL: "http://localhost:1188")
        }
        await transport.waitUntilStarted()
        task.cancel()
        await transport.finishFirstRequest()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await client.translate("Hello", serverURL: "http://localhost:1188") == "你好")
        #expect(await transport.requests == 2)
    }

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

    @Test("Warm and blank spans bypass network slots while longer cold spans start first")
    func batchPrioritizesUncachedParagraphs() async throws {
        let transport = ScheduledTranslationTransport()
        let client = DeepLXTranslationClient(transport: transport)
        _ = try await client.translate("cached", serverURL: "http://localhost:1188")
        await transport.startBlocking()
        let task = Task {
            try await client.translateBatch(
                ["cached", "a", "bb", "ccc", "long paragraph", " \n ", "cached"],
                serverURL: "http://localhost:1188"
            )
        }
        await transport.waitForRequests(4)
        #expect(Set(await transport.texts.dropFirst()) == Set(["bb", "ccc", "long paragraph"]))
        await transport.releaseResponses()
        #expect(try await task.value == ["译cached", "译a", "译bb", "译ccc", "译long paragraph", " \n ", "译cached"])
        #expect(await transport.texts.count == 5)
    }

    @Test("Blank spans keep their whitespace without network requests")
    func preservesBlankSpans() async throws {
        let transport = DeepLXMockTransport(statusCode: 200, body: #"{"data":"unused"}"#)
        let client = DeepLXTranslationClient(transport: transport)
        #expect(try await client.translate(" \n\t ", serverURL: "http://localhost:1188") == " \n\t ")
        #expect(try await client.translateBatch(["", " \n", ""], serverURL: "http://localhost:1188") == ["", " \n", ""])
        #expect(await transport.requests == 0)
    }

    @Test("A fully cached batch performs no additional requests and preserves duplicates")
    func reusesCachedBatch() async throws {
        let transport = BatchTranslationTransport()
        let client = DeepLXTranslationClient(transport: transport)
        _ = try await client.translateBatch(["0", "1", "2"], serverURL: "http://localhost:1188")
        #expect(try await client.translateBatch(["2", "0", "1", "0"], serverURL: "http://localhost:1188") == ["译2", "译0", "译1", "译0"])
        #expect(await transport.requests == 3)
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

private struct NonHTTPTranslationTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(#"{"data":"你好"}"#.utf8),
         URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: -1, textEncodingName: "utf-8"))
    }
}

private actor TranslationTimeoutTransport: HTTPTransport {
    private(set) var requests = 0
    private(set) var deadlines: [TimeInterval] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        deadlines.append(request.timeoutInterval)
        if requests == 1 { throw URLError(.timedOut) }
        return (Data(#"{"data":"你好"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor TranslationCancellationTransport: HTTPTransport {
    private(set) var requests = 0
    private var started: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if requests > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        if requests == 1 {
            started?.resume()
            started = nil
            do { try await Task.sleep(for: .seconds(60)) }
            catch { throw URLError(.cancelled) }
        }
        return (Data(#"{"data":"你好"}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor FailingBatchTranslationTransport: HTTPTransport {
    private(set) var requests = 0
    private(set) var cancelled = 0
    private var allStarted: CheckedContinuation<Void, Never>?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        if requests == 3 { allStarted?.resume(); allStarted = nil }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        if body["text"] == "fail longest" {
            if requests < 3 { await withCheckedContinuation { allStarted = $0 } }
            return (Data(#"{"message":"unavailable"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled += 1; throw error }
        throw URLError(.timedOut)
    }
}

private actor DeepLXMockTransport: HTTPTransport {
    private let statusCode: Int
    private let body: String
    private(set) var lastRequest: URLRequest?
    private(set) var requests = 0

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
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

private actor CancellationIgnoringTranslationTransport: HTTPTransport {
    private(set) var requests = 0
    private var started: CheckedContinuation<Void, Never>?
    private var responseReady: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if requests > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func finishFirstRequest() {
        responseReady?.resume()
        responseReady = nil
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        if requests == 1 {
            await withCheckedContinuation {
                responseReady = $0
                started?.resume()
                started = nil
            }
        }
        return (
            Data(#"{"data":"你好"}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
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

private actor ScheduledTranslationTransport: HTTPTransport {
    private(set) var texts: [String] = []
    private var blocksResponses = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var waitingForCount: Int?
    private var started: CheckedContinuation<Void, Never>?

    func startBlocking() { blocksResponses = true }

    func waitForRequests(_ count: Int) async {
        guard texts.count < count else { return }
        waitingForCount = count
        await withCheckedContinuation { started = $0 }
    }

    func releaseResponses() {
        blocksResponses = false
        for continuation in blocked { continuation.resume() }
        blocked.removeAll()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        let text = body["text"]!
        texts.append(text)
        if let waitingForCount, texts.count >= waitingForCount {
            started?.resume()
            started = nil
            self.waitingForCount = nil
        }
        if blocksResponses {
            await withCheckedContinuation { blocked.append($0) }
        }
        return (
            try JSONSerialization.data(withJSONObject: ["data": "译" + text]),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
