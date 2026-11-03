import Foundation
import MarrCore
@testable import MarrNetworking
import Testing

@Suite("Translation response cache")
struct TranslationResponseCacheTests {
    private func request(_ text: String = "Hello") -> VisionRequest {
        VisionRequest(systemPrompt: "Translate", messages: [VisionMessage(role: .user, content: [.text(text)])])
    }

    @Test("Blank responses cannot populate or replace a valid cached translation", arguments: ["", " \n\t "])
    func rejectsBlankResponses(response: String) async throws {
        let cache = TranslationResponseCache()
        let connection = InferenceConnection.openAI(apiKey: "")
        let original = request()
        try await cache.insert(response, for: original, model: "m", connection: connection)
        #expect(try await cache.value(for: original, model: "m", connection: connection) == nil)
        try await cache.insert("你好", for: original, codexModel: "m", reasoningEffort: nil)
        try await cache.insert(response, for: original, codexModel: "m", reasoningEffort: nil)
        #expect(try await cache.value(for: original, codexModel: "m", reasoningEffort: nil) == "你好")
    }

    @Test("Explicit clearing removes both API and Codex translations")
    func clearsAllConfigurations() async throws {
        let cache = TranslationResponseCache()
        let connection = InferenceConnection.openAI(apiKey: "")
        let original = request()
        try await cache.insert("API", for: original, model: "m", connection: connection)
        try await cache.insert("Codex", for: original, codexModel: "m", reasoningEffort: nil)
        await cache.removeAll()
        #expect(try await cache.value(for: original, model: "m", connection: connection) == nil)
        #expect(try await cache.value(for: original, codexModel: "m", reasoningEffort: nil) == nil)
        try await cache.insert("新的译文", for: original, model: "m", connection: connection)
        #expect(try await cache.value(for: original, model: "m", connection: connection) == "新的译文")
    }

    @Test("Nonpositive capacity and lifetime disable both cache entry points")
    func disabledPolicy() async throws {
        let configurations: [(Int, Duration)] = [(0, .seconds(300)), (-1, .seconds(300)), (16, .zero), (16, .seconds(-1))]
        let connection = InferenceConnection.openAI(apiKey: "")
        let original = request()
        for (capacity, lifetime) in configurations {
            let cache = TranslationResponseCache(capacity: capacity, lifetime: lifetime)
            try await cache.insert("API", for: original, model: "m", connection: connection)
            try await cache.insert("Codex", for: original, codexModel: "m", reasoningEffort: nil)
            #expect(try await cache.value(for: original, model: "m", connection: connection) == nil)
            #expect(try await cache.value(for: original, codexModel: "m", reasoningEffort: nil) == nil)
        }
    }

    @Test("Payload boundaries count UTF-8 bytes and aggregate every request message")
    func byteBoundaries() async throws {
        let cache = TranslationResponseCache()
        let connection = InferenceConnection.openAI(apiKey: "")
        let largestResponse = String(repeating: "x", count: 65_536)
        try await cache.insert(largestResponse, for: request(), model: "m", connection: connection)
        #expect(try await cache.value(for: request(), model: "m", connection: connection) == largestResponse)
        let oversizedChinese = String(repeating: "译", count: 21_846)
        try await cache.insert(oversizedChinese, for: request("oversized"), model: "m", connection: connection)
        #expect(try await cache.value(for: request("oversized"), model: "m", connection: connection) == nil)

        func largeRequest(extra: String) -> VisionRequest {
            VisionRequest(systemPrompt: "T", messages: [
                VisionMessage(role: .user, content: [.text(String(repeating: "x", count: 32_767))]),
                VisionMessage(role: .user, content: [.text(String(repeating: "x", count: 32_768) + extra)])
            ])
        }
        let boundary = largeRequest(extra: "")
        let oversized = largeRequest(extra: "x")
        try await cache.insert("边界", for: boundary, codexModel: "m", reasoningEffort: nil)
        try await cache.insert("超限", for: oversized, codexModel: "m", reasoningEffort: nil)
        #expect(try await cache.value(for: boundary, codexModel: "m", reasoningEffort: nil) == "边界")
        #expect(try await cache.value(for: oversized, codexModel: "m", reasoningEffort: nil) == nil)
    }

    @Test("Concurrent inserts remain isolated and obey the shared capacity")
    func concurrentCapacity() async throws {
        let cache = TranslationResponseCache(capacity: 8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    try await cache.insert("译\(index)", for: request("source\(index)"),
                                           codexModel: "m", reasoningEffort: nil)
                }
            }
            try await group.waitForAll()
        }
        var retained = 0
        for index in 0..<24 {
            if let value = try await cache.value(for: request("source\(index)"), codexModel: "m", reasoningEffort: nil) {
                #expect(value == "译\(index)")
                retained += 1
            }
        }
        #expect(retained == 8)
    }

    @Test("Codex reuses exact requests and isolates models, efforts, prompts and API providers")
    func isolatesCodexConfiguration() async throws {
        let cache = TranslationResponseCache()
        let original = request()
        try await cache.insert("你好", for: original, codexModel: "model", reasoningEffort: "low")
        #expect(try await cache.value(for: original, codexModel: "model", reasoningEffort: "low") == "你好")
        #expect(try await cache.value(for: original, codexModel: "other", reasoningEffort: "low") == nil)
        #expect(try await cache.value(for: original, codexModel: "model", reasoningEffort: "high") == nil)
        #expect(try await cache.value(for: original, codexModel: "model", reasoningEffort: nil) == nil)
        #expect(try await cache.value(for: request("Different"), codexModel: "model", reasoningEffort: "low") == nil)
        let otherPrompt = VisionRequest(systemPrompt: "Translate formally", messages: original.messages)
        #expect(try await cache.value(for: otherPrompt, codexModel: "model", reasoningEffort: "low") == nil)
        let connection = InferenceConnection.openAI(apiKey: "key")
        #expect(try await cache.value(for: original, model: "model", connection: connection) == nil)
        try await cache.insert("API translation", for: original, model: "model", connection: connection)
        #expect(try await cache.value(for: original, codexModel: "model", reasoningEffort: "low") == "你好")
        #expect(try await cache.value(for: original, model: "model", connection: connection) == "API translation")
    }

    @Test("Codex and API entries share one memory limit and preserve recent reads")
    func codexSharesMemoryLimit() async throws {
        let cache = TranslationResponseCache(capacity: 2)
        let connection = InferenceConnection.openAI(apiKey: "")
        try await cache.insert("Codex A", for: request("a"), codexModel: "m", reasoningEffort: nil)
        try await cache.insert("API", for: request(), model: "m", connection: connection)
        _ = try await cache.value(for: request("a"), codexModel: "m", reasoningEffort: nil)
        try await cache.insert("Codex B", for: request("b"), codexModel: "m", reasoningEffort: nil)
        #expect(try await cache.value(for: request(), model: "m", connection: connection) == nil)
        #expect(try await cache.value(for: request("a"), codexModel: "m", reasoningEffort: nil) == "Codex A")
        #expect(try await cache.value(for: request("b"), codexModel: "m", reasoningEffort: nil) == "Codex B")
    }

    @Test("Codex responses expire, reject oversized text and obey cancellation")
    func codexCacheLifetimeAndCancellation() async throws {
        let original = request()
        let cache = TranslationResponseCache(lifetime: .milliseconds(1))
        try await cache.insert("你好", for: original, codexModel: "m", reasoningEffort: nil)
        try await Task.sleep(for: .milliseconds(10))
        #expect(try await cache.value(for: original, codexModel: "m", reasoningEffort: nil) == nil)

        let bounded = TranslationResponseCache()
        let oversized = request(String(repeating: "x", count: 65_537))
        try await bounded.insert("你好", for: oversized, codexModel: "m", reasoningEffort: nil)
        #expect(try await bounded.value(for: oversized, codexModel: "m", reasoningEffort: nil) == nil)
        try await bounded.insert("你好", for: original, codexModel: "m", reasoningEffort: nil)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await bounded.value(for: original, codexModel: "m", reasoningEffort: nil)
            }
            await #expect(throws: CancellationError.self) {
                try await bounded.insert("Cancelled", for: original, codexModel: "m", reasoningEffort: nil)
            }
        }
        await task.value
        #expect(try await bounded.value(for: original, codexModel: "m", reasoningEffort: nil) == "你好")
    }

    @Test("Reuses only the same text, prompt, model and full connection")
    func isolatesConfiguration() async throws {
        let cache = TranslationResponseCache()
        let original = request()
        let connection = InferenceConnection.openAI(apiKey: "key")
        try await cache.insert("你好", for: original, model: "model", connection: connection)
        #expect(try await cache.value(for: original, model: "model", connection: connection) == "你好")
        #expect(try await cache.value(for: request("Different"), model: "model", connection: connection) == nil)
        #expect(try await cache.value(for: original, model: "other-model", connection: connection) == nil)
        let otherPrompt = VisionRequest(systemPrompt: "Translate formally", messages: original.messages)
        #expect(try await cache.value(for: otherPrompt, model: "model", connection: connection) == nil)
        var variants = [InferenceConnection]()
        var changed = connection
        changed.apiKey = "another-key"
        variants.append(changed)
        changed = connection
        changed.baseURL = "https://another.example/v1"
        variants.append(changed)
        changed = connection
        changed.apiFormat = .anthropicMessages
        variants.append(changed)
        changed = connection
        changed.customHeaders = ["X-Account": "another"]
        variants.append(changed)
        for variant in variants {
            #expect(try await cache.value(for: original, model: "model", connection: variant) == nil)
        }
    }

    @Test("Bounded cache evicts the least recently read request")
    func boundsMemory() async throws {
        let cache = TranslationResponseCache(capacity: 2)
        let connection = InferenceConnection.openAI(apiKey: "")
        for text in ["a", "b"] {
            try await cache.insert(text, for: request(text), model: "m", connection: connection)
        }
        _ = try await cache.value(for: request("a"), model: "m", connection: connection)
        try await cache.insert("c", for: request("c"), model: "m", connection: connection)
        #expect(try await cache.value(for: request("a"), model: "m", connection: connection) == "a")
        #expect(try await cache.value(for: request("b"), model: "m", connection: connection) == nil)
    }

    @Test("Expired results and screenshots are not reused")
    func expirationAndImages() async throws {
        let connection = InferenceConnection.openAI(apiKey: "")
        let cache = TranslationResponseCache(lifetime: .milliseconds(1))
        try await cache.insert("你好", for: request(), model: "m", connection: connection)
        try await Task.sleep(for: .milliseconds(10))
        #expect(try await cache.value(for: request(), model: "m", connection: connection) == nil)
        let images = TranslationResponseCache()
        let imageRequest = VisionRequest(systemPrompt: "Translate", messages: [VisionMessage(
            role: .user,
            content: [.image(ConversationImageAsset(data: Data([0]), mimeType: "image/png", fileName: "capture.png"))]
        )])
        try await images.insert("你好", for: imageRequest, model: "m", connection: connection)
        #expect(try await images.value(for: imageRequest, model: "m", connection: connection) == nil)
    }

    @Test("Cancelled requests cannot read or populate the cache")
    func cancellation() async throws {
        let cache = TranslationResponseCache()
        let connection = InferenceConnection.openAI(apiKey: "")
        let request = request()
        try await cache.insert("你好", for: request, model: "m", connection: connection)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await cache.value(for: request, model: "m", connection: connection)
            }
            await #expect(throws: CancellationError.self) {
                try await cache.insert("Cancelled", for: request, model: "m", connection: connection)
            }
        }
        await task.value
        #expect(try await cache.value(for: request, model: "m", connection: connection) == "你好")
    }
}
