import Foundation

public enum DeepLXTranslationClientError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case apiError(String)
    case emptyTranslation

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The DeepLX server URL is invalid."
        case .invalidResponse:
            "The DeepLX server returned an invalid response."
        case .apiError(let message):
            "DeepLX error: \(message)"
        case .emptyTranslation:
            "The DeepLX server returned an empty translation."
        }
    }
}

public struct DeepLXTranslationClient: Sendable {
    private static let requestTimeout: TimeInterval = 30
    private let transport: any HTTPTransport
    private let cache: TranslationCache

    /// Successful translations are retained only in memory. Set `cacheCapacity`
    /// or `cacheLifetime` to zero to disable reuse between requests.
    public init(
        transport: any HTTPTransport = URLSession.shared,
        cacheCapacity: Int = 256,
        cacheLifetime: TimeInterval = 300
    ) {
        self.transport = transport
        cache = TranslationCache(capacity: cacheCapacity, lifetime: cacheLifetime)
    }

    public func clearCache() async {
        await cache.removeAll()
    }

    public func translate(
        _ text: String,
        sourceLanguage: String = "auto",
        targetLanguage: String = "ZH",
        serverURL: String,
        accessToken: String = "",
        useCache: Bool = true
    ) async throws -> String {
        try Task.checkCancellation()
        guard let endpoint = endpoint(from: serverURL) else {
            throw DeepLXTranslationClientError.invalidURL
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let cacheKey = TranslationCache.Key(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            endpoint: endpoint,
            accessToken: accessToken
        )
        if useCache, let translatedText = await cache.value(for: cacheKey) {
            try Task.checkCancellation()
            return translatedText
        }
        return try await translateUncached(cacheKey, useCache: useCache)
    }

    private func translateUncached(_ cacheKey: TranslationCache.Key, useCache: Bool = true) async throws -> String {
        try Task.checkCancellation()
        let cacheGeneration = useCache ? await cache.generation : nil
        try Task.checkCancellation()

        var request = URLRequest(url: cacheKey.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cacheKey.accessToken.isEmpty {
            request.setValue("Bearer \(cacheKey.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            text: cacheKey.text,
            sourceLanguage: cacheKey.sourceLanguage,
            targetLanguage: cacheKey.targetLanguage
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            // URLSession commonly reports cancellation as URLError.cancelled.
            // Preserve real transport failures, but let a cancelled caller take
            // the same cancellation path as a warm-cache or completed request.
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepLXTranslationClientError.invalidResponse
        }

        // Failure envelopes can use an object/array in `data`. Decode their
        // status independently so an unrelated field cannot hide the message.
        let status = try? JSONDecoder().decode(ResponseStatus.self, from: data)
        let message = status?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = message.flatMap { $0.isEmpty ? nil : $0 }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepLXTranslationClientError.apiError(
                diagnostic ?? "HTTP \(httpResponse.statusCode)"
            )
        }
        if let code = status?.code, !(200..<300).contains(code) {
            throw DeepLXTranslationClientError.apiError(diagnostic ?? "Code \(code)")
        }
        guard let payload = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw DeepLXTranslationClientError.invalidResponse
        }
        let translatedText = payload.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translatedText.isEmpty else {
            throw DeepLXTranslationClientError.emptyTranslation
        }
        if let cacheGeneration {
            try await cache.insert(translatedText, for: cacheKey, generation: cacheGeneration)
        }
        try Task.checkCancellation()
        return translatedText
    }

    /// Translate independent OCR spans without changing their context or order.
    /// Exact duplicates share work within the batch and recent results can be reused.
    public func translateBatch(
        _ texts: [String],
        sourceLanguage: String = "auto",
        targetLanguage: String = "ZH",
        serverURL: String,
        accessToken: String = ""
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard !texts.isEmpty else { return [] }
        guard let endpoint = endpoint(from: serverURL) else {
            throw DeepLXTranslationClientError.invalidURL
        }
        var uniqueTexts: [String] = []
        var indexes: [String: Int] = [:]
        let inputIndexes = texts.map { text in
            if let index = indexes[text] { return index }
            let index = uniqueTexts.count
            indexes[text] = index
            uniqueTexts.append(text)
            return index
        }
        let keys = uniqueTexts.map {
            TranslationCache.Key(
                text: $0, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                endpoint: endpoint, accessToken: accessToken
            )
        }
        // Resolve warm entries in one actor hop, before assigning network slots.
        let cached = await cache.values(for: keys)
        try Task.checkCancellation()
        var resolved = uniqueTexts
        var missing: [(index: Int, length: Int)] = []
        for index in uniqueTexts.indices {
            if let translation = cached[index] {
                resolved[index] = translation
            } else if !uniqueTexts[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                missing.append((index, uniqueTexts[index].utf8.count))
            }
        }
        // Start longer spans first so a final paragraph does not wait behind short labels.
        // Only scheduling changes; the source and returned order stay exact.
        let work = missing.sorted {
            $0.length == $1.length ? $0.index < $1.index : $0.length > $1.length
        }.map(\.index)
        guard !work.isEmpty else { return inputIndexes.map { resolved[$0] } }
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var results = resolved
            var next = 0
            func enqueue(_ position: Int) {
                let index = work[position]
                group.addTask {
                    try Task.checkCancellation()
                    let translated = try await translateUncached(keys[index])
                    return (index, translated)
                }
            }
            // Bound upstream load, including selective spans within a region.
            while next < min(3, work.count) {
                enqueue(next)
                next += 1
            }
            while let (index, translated) = try await group.next() {
                try Task.checkCancellation()
                results[index] = translated
                if next < work.count {
                    enqueue(next)
                    next += 1
                }
            }
            return results
        }
        try Task.checkCancellation()
        return inputIndexes.map { results[$0] }
    }

    private func endpoint(from serverURL: String) -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            return nil
        }

        var pathComponents = components.path
            .split(separator: "/")
            .map(String.init)
        if pathComponents.last != "translate" {
            pathComponents.append("translate")
        }
        components.path = "/" + pathComponents.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// Per-client storage keeps OCR content and credentials out of persistent caches.
/// Requests are not shared in flight, so cancelling one caller cannot cancel another.
private actor TranslationCache {
    struct Key: Hashable, Sendable {
        let text: String
        let sourceLanguage: String
        let targetLanguage: String
        let endpoint: URL
        let accessToken: String
    }

    private struct Entry {
        let value: String
        let expiresAt: ContinuousClock.Instant
        var lastAccess: UInt64
    }

    private let capacity: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()
    private var entries: [Key: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private(set) var generation: UInt64 = 0

    init(capacity: Int, lifetime: TimeInterval) {
        self.capacity = lifetime.isFinite && lifetime > 0 ? max(0, capacity) : 0
        self.lifetime = .seconds(lifetime.isFinite && lifetime > 0 ? lifetime : 0)
    }

    func value(for key: Key) -> String? {
        guard var entry = entries[key] else { return nil }
        guard clock.now < entry.expiresAt else {
            entries.removeValue(forKey: key)
            return nil
        }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        return entry.value
    }

    func values(for keys: [Key]) -> [String?] {
        keys.map { value(for: $0) }
    }

    func insert(_ value: String, for key: Key, generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == self.generation, capacity > 0, !value.isEmpty,
              value.utf8.count <= 65_536, key.text.utf8.count <= 65_536,
              !key.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let now = clock.now
        entries = entries.filter { now < $0.value.expiresAt }
        if entries[key] == nil, entries.count >= capacity,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldest)
        }
        accessCounter &+= 1
        entries[key] = Entry(
            value: value,
            expiresAt: now.advanced(by: lifetime),
            lastAccess: accessCounter
        )
    }

    func removeAll() {
        entries.removeAll()
        generation &+= 1
    }
}

private extension DeepLXTranslationClient {
    struct RequestBody: Encodable {
        let text: String
        let sourceLanguage: String
        let targetLanguage: String

        enum CodingKeys: String, CodingKey {
            case text
            case sourceLanguage = "source_lang"
            case targetLanguage = "target_lang"
        }
    }

    struct ResponseBody: Decodable {
        let code: Int?
        let data: String
    }

    struct ResponseStatus: Decodable {
        let code: Int?
        let message: String?

        enum CodingKeys: String, CodingKey { case code, message }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
        }
    }
}
