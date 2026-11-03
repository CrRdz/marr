import Foundation
import Network

/// Lives only for one authorization attempt. No wildcard interfaces or persistent HTTP server.
@MainActor
final class ChatGPTLoopback {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var redirectURI: URL?
    private var expectedState: String?
    private var timeout: Task<Void, Never>?

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port else { return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.redirectURI = url
                    self.ready?.resume(returning: url); self.ready = nil
                case .failed:
                    self.finish(.failure(ChatGPTAuthError.message("Could not open the local ChatGPT sign-in callback.")))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.finish(.failure(ChatGPTAuthError.message("ChatGPT sign-in timed out. Please try again.")))
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func wait(state: String) async throws -> URL {
        expectedState = state
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { callback = $0 }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func prepare(state: String) { expectedState = state }
    func cancel() { finish(.failure(CancellationError())) }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16_384, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
                guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { self.connections.removeValue(forKey: id)?.cancel() }
                    else { self.receive(connection, id: id, buffer: bytes) }
                    return
                }
                let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
                let first = (lines.first ?? "").split(separator: " ")
                let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let expectedHost = self.redirectURI.map { "127.0.0.1:\($0.port!)" }
                var url: URL?
                if first.count == 3, first[0] == "GET", first[1].hasPrefix("/auth/callback?"), host == expectedHost,
                   let base = self.redirectURI,
                   let candidate = URL(string: String(first[1]), relativeTo: base)?.absoluteURL,
                   let items = URLComponents(url: candidate, resolvingAgainstBaseURL: false)?.queryItems,
                   items.filter({ $0.name == "state" }).count == 1,
                   items.first(where: { $0.name == "state" })?.value == self.expectedState {
                    url = candidate
                }
                let body = url == nil ? "Invalid sign-in callback." : "Authorization received. Return to Marr to finish sign-in."
                let response = "HTTP/1.1 \(url == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                let callbackURL = url
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    Task { @MainActor in
                        self.connections.removeValue(forKey: id)?.cancel()
                        if let callbackURL { self.finish(.success(callbackURL)) }
                    }
                })
            }
        }
    }

    private func finish(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value
        ready?.resume(with: value); ready = nil
        callback?.resume(with: value); callback = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
}
