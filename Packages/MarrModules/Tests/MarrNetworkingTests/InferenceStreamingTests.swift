import Foundation
import MarrCore
@testable import MarrNetworking
import Testing

@Suite("Conversation streaming")
@MainActor
struct InferenceStreamingTests {
    private let request = VisionRequest(systemPrompt: "system", messages: [.init(role: .user, content: [.text("hello")])])

    @Test("An answer is observable before the provider closes its stream")
    func firstTextArrivesBeforeCompletion() async throws {
        let transport = ControlledStreamTransport()
        let recorder = StreamEventRecorder()
        let task = Task {
            let result = try await InferenceClient(transport: transport).askStreaming(
                request: request, model: "test", connection: connection(.openAIResponses),
                onEvent: { recorder.receive($0) })
            recorder.completed = true
            return result
        }
        await transport.waitUntilConnected()
        await transport.yield(#"data: {"type":"response.output_text.delta","delta":"你","output_index":0,"content_index":0}"# + "\n\n")
        await recorder.waitForText()
        #expect(recorder.texts == ["你"])
        #expect(!recorder.completed)
        await transport.yield(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"output_text","text":"你好"}]}],"usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n\n")
        await transport.finish()
        let result = try await task.value
        #expect(result.text == "你好")
        #expect(result.usage == .init(inputTokens: 10, outputTokens: 2))
        #expect(recorder.texts.last == "你好")
    }

    @Test("All provider formats preserve deltas and their final usage")
    func providerFormats() async throws {
        let cases: [(GatewayAPIFormat, String, InferenceTokenUsage)] = [
            (.openAIChatCompletions, """
            data: {"choices":[{"index":0,"delta":{"content":"hello "},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{"content":"world"},"finish_reason":"stop"}]}

            data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}

            data: [DONE]


            """, .init(inputTokens: 7, outputTokens: 2)),
            (.anthropicMessages, """
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":3,"cache_read_input_tokens":4,"output_tokens":0}}}

            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

            data: {"type":"message_stop"}


            """, .init(inputTokens: 12, outputTokens: 2))
        ]
        for (format, sse, usage) in cases {
            let transport = ScriptedStreamTransport([.init(body: sse)])
            let recorder = StreamEventRecorder()
            let result = try await InferenceClient(transport: transport).askStreaming(
                request: request, model: "test", connection: connection(format), onEvent: { recorder.receive($0) })
            #expect(result.text == "hello world")
            #expect(result.usage == usage)
            #expect(recorder.events.contains(.usage(usage)))
            #expect(!recorder.texts.joined().contains("private"))
        }
    }

    @Test("UTF-8 split across bytes, CRLF and multiline SSE fields are decoded")
    func sseBoundaries() throws {
        var decoder = InferenceSSEDecoder()
        var events: [InferenceSSEDecoder.Event] = []
        for byte in Data(":keepalive\r\nevent: custom\r\ndata: 你\r\ndata: 好\r\n\r\n".utf8) {
            events += try decoder.append(Data([byte]))
        }
        #expect(events.count == 1)
        #expect(events.first?.name == "custom")
        #expect(events.first?.data == "你\n好")
    }

    @Test("An unfinished stream keeps its text and does not retry")
    func disconnectAfterContent() async throws {
        let transport = ScriptedStreamTransport([.init(
            body: #"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n")])
        let recorder = StreamEventRecorder()
        await #expect(throws: InferenceClientError.incompleteStream) {
            try await InferenceClient(transport: transport).askStreaming(
                request: request, model: "test", connection: connection(.openAIResponses), onEvent: { recorder.receive($0) })
        }
        #expect(recorder.texts.last == "partial")
        #expect(await transport.requests.count == 1)
    }

    @Test("Malformed and explicit error events preserve earlier answer content")
    func malformedAndErrorEvents() async throws {
        for (tail, expected) in [
            ("data: {invalid-json}\n\n", InferenceClientError.invalidResponse),
            (#"data: {"type":"error","error":{"message":"overloaded"}}"# + "\n\n", .apiError("overloaded"))
        ] {
            let transport = ScriptedStreamTransport([.init(
                body: #"data: {"type":"response.output_text.delta","delta":"kept"}"# + "\n\n" + tail)])
            let recorder = StreamEventRecorder()
            await #expect(throws: expected) {
                try await InferenceClient(transport: transport).askStreaming(
                    request: request, model: "test", connection: connection(.openAIResponses), onEvent: { recorder.receive($0) })
            }
            #expect(recorder.texts.last == "kept")
            #expect(await transport.requests.count == 1)
        }
    }

    @Test("Cancelling an open stream terminates without completing or replaying it")
    func cancelOpenStream() async throws {
        let transport = ControlledStreamTransport()
        let recorder = StreamEventRecorder()
        let task = Task {
            try await InferenceClient(transport: transport).askStreaming(
                request: request, model: "test", connection: connection(.openAIResponses), onEvent: { recorder.receive($0) })
        }
        await transport.waitUntilConnected()
        await transport.yield(#"data: {"type":"response.output_text.delta","delta":"partial"}"# + "\n\n")
        await recorder.waitForText()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.texts == ["partial"])
        await transport.finish()
    }

    @Test("Output-limit errors retain partial text and reported usage")
    func truncatedStream() async throws {
        let transport = ScriptedStreamTransport([.init(body: """
        data: {"type":"response.output_text.delta","delta":"partial"}

        data: {"type":"response.incomplete","response":{"status":"incomplete","output":[],"usage":{"input_tokens":8,"output_tokens":3}}}


        """)])
        let recorder = StreamEventRecorder()
        await #expect(throws: InferenceClientError.outputTruncated) {
            try await InferenceClient(transport: transport).askStreaming(
                request: request, model: "test", connection: connection(.openAIResponses), onEvent: { recorder.receive($0) })
        }
        #expect(recorder.texts.last == "partial")
        #expect(recorder.events.contains(.usage(.init(inputTokens: 8, outputTokens: 3))))
        #expect(await transport.requests.count == 1)
    }

    @Test("429 rejection respects Retry-After and retry state precedes the next request")
    func retryAfterRejection() async throws {
        let transport = ScriptedStreamTransport([
            .init(status: 429, headers: ["Retry-After": "3"], body: #"{"error":{"message":"slow down"}}"#),
            .init(headers: ["Content-Type": "application/json"], body: #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
        ])
        let sleeps = RetrySleepRecorder()
        let recorder = StreamEventRecorder()
        let result = try await InferenceClient(transport: transport, retrySleep: { await sleeps.append($0) }).askStreaming(
            request: request, model: "test", connection: connection(.openAIChatCompletions), onEvent: { recorder.receive($0) })
        #expect(result.text == "ok")
        #expect(await sleeps.values == [3])
        #expect(await transport.requests.count == 2)
        #expect(recorder.events.filter { $0 == .requestStarted }.count == 2)
        #expect(recorder.events.contains { if case .retryScheduled(attempt: 1, resumeAt: _) = $0 { true } else { false } })
    }

    @Test("Retries are bounded and cancellation during backoff sends no next request")
    func boundedAndCancelledRetries() async throws {
        let rejection = StreamReply(status: 503, body: #"{"error":{"message":"unavailable"}}"#)
        let transport = ScriptedStreamTransport([rejection, rejection, rejection])
        let sleeps = RetrySleepRecorder()
        await #expect(throws: InferenceClientError.apiError("unavailable")) {
            try await InferenceClient(transport: transport, retrySleep: { await sleeps.append($0) }).askStreaming(
                request: request, model: "test", connection: connection(.openAIResponses), onEvent: { _ in })
        }
        #expect(await transport.requests.count == 3)
        #expect(await sleeps.values == [1, 2])
        let cancelled = ScriptedStreamTransport([rejection])
        await #expect(throws: CancellationError.self) {
            try await InferenceClient(transport: cancelled, retrySleep: { _ in throw CancellationError() }).askStreaming(
                request: request, model: "test", connection: connection(.openAIResponses), onEvent: { _ in })
        }
        #expect(await cancelled.requests.count == 1)
    }

    @Test("Ambiguous transport failures are not automatically replayed")
    func noNetworkRetry() async throws {
        let transport = ScriptedStreamTransport([.init(body: "", error: .networkConnectionLost)])
        await #expect(throws: URLError(.networkConnectionLost)) {
            try await InferenceClient(transport: transport).askStreaming(
                request: request, model: "test", connection: connection(.openAIResponses), onEvent: { _ in })
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("A gateway's explicit stream rejection falls back once without changing attachments")
    func rejectedStreamingFallback() async throws {
        let transport = ScriptedStreamTransport([
            .init(status: 400, body: #"{"error":{"message":"stream is not supported"}}"#),
            .init(headers: ["Content-Type": "text/plain"], body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)
        ])
        let result = try await InferenceClient(transport: transport).askStreaming(
            request: request, model: "test", connection: connection(.anthropicMessages), onEvent: { _ in })
        #expect(result.text == "ok")
        let bodies = try await transport.requests.map { try JSONSerialization.jsonObject(with: #require($0.httpBody)) as! [String: Any] }
        #expect(bodies.count == 2)
        #expect(bodies[0]["stream"] as? Bool == true)
        #expect(bodies[1]["stream"] as? Bool == false)
        #expect(bodies[0]["messages"] as? NSArray == bodies[1]["messages"] as? NSArray)
    }

    @Test("HTTP-date waits are honored; long and invalid waits never retry early")
    func retryDates() {
        let now = Date(timeIntervalSince1970: 0)
        func response(_ value: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": value])!
        }
        #expect(InferenceRetryPolicy.delay(response: response("Thu, 01 Jan 1970 00:00:12 GMT"), retry: 0, now: now) == 12)
        #expect(InferenceRetryPolicy.delay(response: response("3600"), retry: 0, now: now) == nil)
        #expect(InferenceRetryPolicy.delay(response: response("not-a-date"), retry: 0, now: now) == nil)
    }

    private func connection(_ format: GatewayAPIFormat) -> InferenceConnection {
        .init(provider: .gateway, baseURL: "https://example.com/v1", apiKey: "", authScheme: .none, apiFormat: format, customHeaders: [:])
    }
}

private struct StreamReply: Sendable {
    var status = 200
    var headers = ["Content-Type": "text/event-stream"]
    var body: String
    var error: URLError.Code?
}

private actor ScriptedStreamTransport: HTTPTransport {
    private var replies: [StreamReply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [StreamReply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.unsupportedURL) }
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (AsyncThrowingStream { continuation in
            // Byte fragmentation exercises UTF-8 and SSE frame boundaries, not only whole-body parsing.
            for byte in reply.body.utf8 { continuation.yield(Data([byte])) }
            if let error = reply.error { continuation.finish(throwing: URLError(error)) }
            else { continuation.finish() }
        }, response)
    }
}

private actor ControlledStreamTransport: HTTPTransport {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var connected: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.unsupportedURL) }
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        connected?.resume()
        connected = nil
        return (pair.stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!)
    }
    func waitUntilConnected() async {
        if continuation == nil { await withCheckedContinuation { connected = $0 } }
    }
    func yield(_ text: String) { continuation?.yield(Data(text.utf8)) }
    func finish() { continuation?.finish() }
}

@MainActor
private final class StreamEventRecorder {
    var events: [VisionResponseEvent] = []
    var completed = false
    private var textWaiter: CheckedContinuation<Void, Never>?
    var texts: [String] { events.compactMap { if case .text(let text) = $0 { text } else { nil } } }
    func receive(_ event: VisionResponseEvent) {
        events.append(event)
        if case .text = event { textWaiter?.resume(); textWaiter = nil }
    }
    func waitForText() async {
        if texts.isEmpty { await withCheckedContinuation { textWaiter = $0 } }
    }
}

private actor RetrySleepRecorder {
    private(set) var values: [TimeInterval] = []
    func append(_ value: TimeInterval) { values.append(value) }
}
