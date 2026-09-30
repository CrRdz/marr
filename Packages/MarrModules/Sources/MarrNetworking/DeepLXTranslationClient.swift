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

    public init(transport: any HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    public func translate(
        _ text: String,
        sourceLanguage: String = "auto",
        targetLanguage: String = "ZH",
        serverURL: String,
        accessToken: String = ""
    ) async throws -> String {
        guard let endpoint = endpoint(from: serverURL) else {
            throw DeepLXTranslationClientError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ))

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepLXTranslationClientError.invalidResponse
        }

        let payload = try? JSONDecoder().decode(ResponseBody.self, from: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepLXTranslationClientError.apiError(
                payload?.message ?? "HTTP \(httpResponse.statusCode)"
            )
        }
        guard let translatedText = payload?.data?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translatedText.isEmpty
        else {
            throw DeepLXTranslationClientError.emptyTranslation
        }
        return translatedText
    }

    /// Translate independent OCR spans without changing their context or order.
    /// Deduplication is limited to this batch, so no stale translations are retained.
    public func translateBatch(
        _ texts: [String],
        sourceLanguage: String = "auto",
        targetLanguage: String = "ZH",
        serverURL: String,
        accessToken: String = ""
    ) async throws -> [String] {
        try Task.checkCancellation()
        var uniqueTexts: [String] = []
        var indexes: [String: Int] = [:]
        let inputIndexes = texts.map { text in
            if let index = indexes[text] { return index }
            let index = uniqueTexts.count
            indexes[text] = index
            uniqueTexts.append(text)
            return index
        }
        let work = uniqueTexts
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var results = Array(repeating: "", count: work.count)
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask {
                    try Task.checkCancellation()
                    let translated = try await translate(
                        work[index],
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        serverURL: serverURL,
                        accessToken: accessToken
                    )
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
              components.host != nil
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
        let data: String?
        let message: String?
    }
}
