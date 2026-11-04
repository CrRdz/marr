import Foundation
import MarrCore

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse)
}

public extension HTTPTransport {
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        let (data, response) = try await data(for: request)
        return (AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        }, response)
    }
}

extension URLSession: HTTPTransport {
    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        let (bytes, response) = try await bytes(for: request)
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(1_024)) { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if byte == 10 || chunk.count >= 8_192 {
                            switch continuation.yield(chunk) {
                            case .enqueued: break
                            case .dropped: throw InferenceClientError.invalidResponse
                            case .terminated:
                                bytes.task.cancel()
                                return
                            @unknown default: throw InferenceClientError.invalidResponse
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty, case .dropped = continuation.yield(chunk) {
                        throw InferenceClientError.invalidResponse
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                bytes.task.cancel()
            }
        }
        return (stream, response)
    }
}
