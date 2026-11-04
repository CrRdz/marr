import Foundation
import MarrCore

enum InferenceResponseStream {
    static func consume(
        _ chunks: AsyncThrowingStream<Data, Error>,
        response: HTTPURLResponse,
        format: GatewayAPIFormat,
        requiresCompletedEvent: Bool = false,
        onEvent: @escaping VisionResponseHandler
    ) async throws -> VisionResponse {
        var decoder = InferenceSSEDecoder()
        var accumulator = InferenceStreamAccumulator(format: format)
        var buffered = Data()
        let mime = response.mimeType?.lowercased() ?? ""
        var isJSON: Bool? = mime.contains("json") ? true : mime.contains("event-stream") ? false : nil
        var published = ""
        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                if isJSON == nil {
                    buffered.append(chunk)
                    guard buffered.count <= 16_000_000 else { throw InferenceClientError.invalidResponse }
                    let prefix = String(decoding: buffered.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if prefix.isEmpty { continue }
                    isJSON = prefix.hasPrefix("{") || prefix.hasPrefix("[")
                    if isJSON == false {
                        for event in try decoder.append(buffered) { try accumulator.consume(event) }
                        buffered.removeAll()
                    }
                } else if isJSON == true {
                    buffered.append(chunk)
                    guard buffered.count <= 16_000_000 else { throw InferenceClientError.invalidResponse }
                } else {
                    for event in try decoder.append(chunk) { try accumulator.consume(event) }
                }
                if accumulator.text != published {
                    published = accumulator.text
                    await onEvent(.text(published))
                }
                try checkFailure(accumulator, response: response, requiresCompletedEvent: requiresCompletedEvent)
                if accumulator.receivedTerminator { break }
            }
            try Task.checkCancellation()
            if requiresCompletedEvent && isJSON == true { throw InferenceClientError.incompleteStream }
            if isJSON == true {
                guard let decoded = try? JSONSerialization.jsonObject(with: buffered),
                      let object = decoded as? [String: Any] else {
                    throw InferenceClientError.invalidResponse
                }
                accumulator.consumeCompleteResponse(object)
            } else if !accumulator.receivedTerminator {
                for event in try decoder.append(Data(), endOfStream: true) { try accumulator.consume(event) }
            }
            if accumulator.text != published {
                published = accumulator.text
                await onEvent(.text(published))
            }
            try checkFailure(accumulator, response: response, requiresCompletedEvent: requiresCompletedEvent)
            if requiresCompletedEvent && !accumulator.receivedCompletedEvent { throw InferenceClientError.incompleteStream }
            guard accumulator.isComplete else { throw InferenceClientError.incompleteStream }
            guard !accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InferenceClientError.emptyAnswer
            }
            if let usage = accumulator.usage { await onEvent(.usage(usage)) }
            return VisionResponse(text: accumulator.text, usage: accumulator.usage)
        } catch {
            if !Task.isCancelled {
                if accumulator.text != published { await onEvent(.text(accumulator.text)) }
            }
            if let usage = accumulator.usage { await onEvent(.usage(usage)) }
            throw error
        }
    }

    private static func checkFailure(_ accumulator: InferenceStreamAccumulator,
                                     response: HTTPURLResponse, requiresCompletedEvent: Bool) throws {
        guard let failure = accumulator.failure else { return }
        if requiresCompletedEvent, accumulator.errorCode != nil {
            throw ChatGPTAPIError(status: response.statusCode, code: accumulator.errorCode,
                parameter: accumulator.errorParameter, requestID: response.value(forHTTPHeaderField: "x-request-id"),
                message: accumulator.errorMessage ?? failure.localizedDescription)
        }
        throw failure
    }
}
