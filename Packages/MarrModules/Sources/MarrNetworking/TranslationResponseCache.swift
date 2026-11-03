import Foundation
import MarrCore

/// Session-local text translations. Credentials and request data never leave memory.
/// Callers insert only responses that passed their translation-format validation.
public actor TranslationResponseCache {
    private enum Configuration: Equatable {
        case ai(model: String, connection: InferenceConnection)
        case codex(model: String, reasoningEffort: String?)
    }

    private struct Entry {
        let request: VisionRequest
        let configuration: Configuration
        let response: String
        let expiresAt: ContinuousClock.Instant
    }

    private var entries: [Entry] = []
    private let capacity: Int
    private let lifetime: Duration
    private let clock = ContinuousClock()

    public init(capacity: Int = 16, lifetime: Duration = .seconds(300)) {
        self.capacity = max(0, capacity)
        self.lifetime = lifetime
    }

    public func removeAll() {
        entries.removeAll()
    }

    public func value(
        for request: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) throws -> String? {
        try value(for: request, configuration: .ai(model: model, connection: connection))
    }

    public func value(
        for request: VisionRequest,
        codexModel: String,
        reasoningEffort: String?
    ) throws -> String? {
        try value(for: request, configuration: .codex(model: codexModel, reasoningEffort: reasoningEffort))
    }

    private func value(for request: VisionRequest, configuration: Configuration) throws -> String? {
        try Task.checkCancellation()
        entries.removeAll { $0.expiresAt <= clock.now }
        guard let index = entries.firstIndex(where: {
            $0.request == request && $0.configuration == configuration
        }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.response
    }

    public func insert(
        _ response: String,
        for request: VisionRequest,
        model: String,
        connection: InferenceConnection
    ) throws {
        try insert(response, for: request, configuration: .ai(model: model, connection: connection))
    }

    public func insert(
        _ response: String,
        for request: VisionRequest,
        codexModel: String,
        reasoningEffort: String?
    ) throws {
        try insert(response, for: request, configuration: .codex(model: codexModel, reasoningEffort: reasoningEffort))
    }

    private func insert(_ response: String, for request: VisionRequest, configuration: Configuration) throws {
        try Task.checkCancellation()
        guard capacity > 0, lifetime > .zero,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.utf8.count <= 65_536 else { return }
        // Avoid retaining screenshots or unbounded document payloads.
        var requestBytes = request.systemPrompt.utf8.count
        for message in request.messages {
            for content in message.content {
                guard case .text(let text) = content else { return }
                requestBytes += text.utf8.count
            }
        }
        guard requestBytes <= 65_536 else { return }
        entries.removeAll {
            $0.expiresAt <= clock.now ||
                ($0.request == request && $0.configuration == configuration)
        }
        if entries.count >= capacity { entries.removeFirst() }
        entries.append(Entry(
            request: request, configuration: configuration,
            response: response, expiresAt: clock.now.advanced(by: lifetime)
        ))
    }
}
