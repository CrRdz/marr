import Combine
import Foundation
import Security

/// One owner-controlled service. Remote state never overwrites the local archive.
@MainActor
final class PersonalAgentCloud: ObservableObject {
    @Published private(set) var scope = "local"
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var address = ""
    @Published private(set) var archive = PersonalAgentArchive(agents: [])
    @Published private(set) var pendingAgents = Set<UUID>()
    @Published private(set) var error: String?
    @Published private(set) var lastSynced: Date?
    private(set) var requests: [UUID: [CodexInteractionRequest]] = [:]
    private var token = ""
    private var serviceID: String?
    private var revision = -1
    private var generation = UUID()
    private var polling: Task<Void, Never>?
    private var retries: [UUID: (prompt: String, routine: UUID?, id: UUID)] = [:]
    private let persistent: Bool
    private let defaults: UserDefaults
    private let session: URLSession
    private let redirectDelegate = AgentCloudRedirectDelegate()
    private static let key = "marr.personalAgent.cloud"

    init(persistent: Bool = false, defaults: UserDefaults = .standard, configuration: URLSessionConfiguration = .ephemeral) {
        self.persistent = persistent; self.defaults = defaults
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        if persistent, defaults.bool(forKey: Self.key + ".enabled") {
            enabled = true
            address = defaults.string(forKey: Self.key + ".address") ?? ""
            serviceID = defaults.string(forKey: Self.key + ".serviceID")
            scope = "cloud:" + address + ":" + (serviceID ?? "")
            do { token = try Self.readToken(address) }
            catch { self.error = error.localizedDescription }
        }
    }

    deinit { polling?.cancel(); session.invalidateAndCancel() }

    static func endpoint(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw PersonalAgentFailure.message("Use an HTTPS server origin, for example https://agents.example.com. HTTP is allowed only on this Mac.")
        }
        return url
    }

    func connect(address: String, token: String) async throws {
        let url = try Self.endpoint(address)
        let clean = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = persistent ? (try? Self.readToken(clean)) : self.token
        let key = credential.isEmpty ? (existing ?? "") : credential
        guard key.count >= 32 else { throw PersonalAgentFailure.message("Enter the service access token (at least 32 characters).") }
        let data = try await fetch(base: url, token: key, action: nil)
        let snapshot = try decode(data)
        if persistent { try Self.saveToken(key, account: clean) }
        polling?.cancel(); polling = nil; generation = UUID()
        self.address = clean; self.token = key; enabled = true
        serviceID = nil; revision = -1; retries = [:]; pendingAgents = []
        try apply(snapshot)
        scope = "cloud:" + clean + ":" + snapshot.serviceID
        if persistent {
            defaults.set(clean, forKey: Self.key + ".address")
            defaults.set(snapshot.serviceID, forKey: Self.key + ".serviceID")
            defaults.set(true, forKey: Self.key + ".enabled")
        }
        start()
    }

    func useLocal() {
        polling?.cancel(); polling = nil; generation = UUID()
        enabled = false; scope = "local"; connected = false; requests = [:]; pendingAgents = []; retries = [:]
        archive = PersonalAgentArchive(agents: []); revision = -1; serviceID = nil; error = nil
        if persistent { defaults.set(false, forKey: Self.key + ".enabled") }
    }

    func start() {
        guard enabled, polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    func suspend() { polling?.cancel(); polling = nil }

    func refresh() async {
        guard enabled else { return }
        let epoch = generation
        do {
            let data = try await fetch(base: Self.endpoint(address), token: token, action: nil)
            guard epoch == generation else { return }
            try apply(decode(data))
        } catch {
            guard epoch == generation, !Task.isCancelled else { return }
            connected = false; self.error = error.localizedDescription
        }
    }

    func action(_ payload: [String: Any]) async throws {
        guard enabled, connected else { throw PersonalAgentFailure.message("Reconnect to your cloud service before making changes.") }
        let epoch = generation
        let data = try await fetch(base: Self.endpoint(address), token: token, action: payload)
        guard epoch == generation else { throw CancellationError() }
        try apply(decode(data))
    }

    func send(_ prompt: String, agentID: UUID, routineID: UUID?) async throws {
        guard !pendingAgents.contains(agentID) else { return }
        let previous = retries[agentID]
        let id = previous?.prompt == prompt && previous?.routine == routineID ? previous!.id : UUID()
        retries[agentID] = (prompt, routineID, id)
        pendingAgents.insert(agentID)
        defer { pendingAgents.remove(agentID) }
        var body: [String: Any] = ["action": "send", "id": id.uuidString, "agentID": agentID.uuidString, "prompt": prompt]
        if let routineID { body["routineID"] = routineID.uuidString }
        try await action(body)
        retries[agentID] = nil
    }

    func save<T: Encodable>(_ item: T, collection: String) async throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let object = try JSONSerialization.jsonObject(with: encoder.encode(item))
        try await action(["action": "save", "collection": collection, "item": object])
    }

    private struct Snapshot {
        let serviceID: String
        let revision: Int
        let archive: PersonalAgentArchive
        let requests: [UUID: [CodexInteractionRequest]]
    }

    private func decode(_ data: Data) throws -> Snapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["protocolVersion"] as? Int == 1,
              let id = object["serviceID"] as? String, let revision = object["revision"] as? Int,
              let archiveJSON = object["archive"] else {
            throw PersonalAgentFailure.message("This server does not support Marr Agent protocol 1.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let archive = try decoder.decode(PersonalAgentArchive.self, from: JSONSerialization.data(withJSONObject: archiveJSON))
        guard archive.version == 1 else { throw PersonalAgentFailure.message("Update Marr to use this server archive.") }
        var requests: [UUID: [CodexInteractionRequest]] = [:]
        for value in object["interactions"] as? [[String: Any]] ?? [] {
            guard let raw = value["id"], let requestID = CodexRequestID(raw),
                  let run = (value["runID"] as? String).flatMap(UUID.init(uuidString:)),
                  let method = value["method"] as? String, let params = value["params"] as? [String: Any] else { continue }
            requests[run, default: []].append(CodexInteractionRequest(id: requestID, method: method, params: params))
        }
        return Snapshot(serviceID: id, revision: revision, archive: archive, requests: requests)
    }

    private func apply(_ snapshot: Snapshot) throws {
        guard serviceID == nil || serviceID == snapshot.serviceID else {
            throw PersonalAgentFailure.message("The server identity changed. Reconnect in Settings to verify it.")
        }
        if snapshot.revision >= revision {
            archive = snapshot.archive; requests = snapshot.requests
            serviceID = snapshot.serviceID; revision = snapshot.revision
        }
        connected = true; error = nil; lastSynced = Date()
    }

    private func fetch(base: URL, token: String, action: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(action == nil ? "v1/state" : "v1/action"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let action {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: action)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PersonalAgentFailure.message(status == 401 ? "The server rejected this access token." : message ?? "Cloud request failed (\(status)).")
        }
        return data
    }

    private static func keychain(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: key, kSecAttrAccount as String: account]
    }
    private static func readToken(_ account: String) throws -> String {
        var query = keychain(account); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw PersonalAgentFailure.message("Re-enter the cloud access token in Settings.")
        }
        return token
    }
    private static func saveToken(_ token: String, account: String) throws {
        let query = keychain(account)
        let value = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query.merging(value) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PersonalAgentFailure.message("Could not save the access token in Keychain (\(status)).") }
    }
}

private final class AgentCloudRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a bearer credential to a redirected host.
    }
}
