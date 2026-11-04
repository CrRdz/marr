import Foundation

public struct ChatGPTProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let email: String?
    public let isSignedIn: Bool
    public let canUsePlan: Bool

    public init(id: String, label: String, email: String?, isSignedIn: Bool, canUsePlan: Bool) {
        self.id = id
        self.label = label
        self.email = email
        self.isSignedIn = isSignedIn
        self.canUsePlan = canUsePlan
    }
}

public struct ChatGPTModel: Codable, Identifiable, Equatable, Sendable {
    public let slug: String
    public let displayName: String
    public let visibility: String
    private let advertisedReasoningEfforts: [String]?
    public var id: String { slug }

    public var supportsFastMode: Bool {
        switch slug {
        case "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna":
            return true
        default:
            return false
        }
    }

    public var fastModeDescription: String {
        "Faster responses with higher plan usage"
    }

    /// The plan catalog guarantees a slug and display name, but effort metadata
    /// is optional. Offer only the common levels for known reasoning families.
    public var reasoningEfforts: [String] {
        if let advertisedReasoningEfforts { return advertisedReasoningEfforts }
        switch slug {
        case "gpt-6.1-sol", "gpt-6-astra":
            return ["low", "medium", "high", "xhigh", "max"]
        case "gpt-6-sol", "gpt-6-luna":
            return ["none", "low", "medium", "high", "xhigh", "max"]
        case "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna":
            return ["low", "medium", "high"]
        default:
            return []
        }
    }

    enum CodingKeys: String, CodingKey {
        case slug, visibility
        case displayName = "display_name"
        case advertisedReasoningEfforts = "supported_reasoning_efforts"
    }

    private struct ReasoningOption: Decodable {
        let reasoningEffort: String
        enum CodingKeys: String, CodingKey {
            case reasoningEffort = "reasoning_effort"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        displayName = try container.decode(String.self, forKey: .displayName)
        visibility = try container.decode(String.self, forKey: .visibility)
        if let efforts = try? container.decode([String].self, forKey: .advertisedReasoningEfforts) {
            advertisedReasoningEfforts = efforts
        } else if let options = try? container.decode([ReasoningOption].self, forKey: .advertisedReasoningEfforts) {
            advertisedReasoningEfforts = options.map(\.reasoningEffort)
        } else {
            advertisedReasoningEfforts = nil
        }
    }
}

struct ChatGPTTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String
    var scopes: [String]
    var expiresAt: Date
}

struct ChatGPTRegistration: Codable, Sendable {
    let clientID: String
    let label: String
    var identity: ChatGPTIdentity?
    var tokens: ChatGPTTokens?
    var modelCatalog: ChatGPTModelCatalog? = nil
}

struct ChatGPTModelCatalog: Codable, Equatable, Sendable {
    let models: [ChatGPTModel]
    let fetchedAt: Date
}

struct ChatGPTSavedState: Codable, Sendable {
    var hostID = "urn:uuid:\(UUID().uuidString.lowercased())"
    var activeID: String?
    var registrations: [ChatGPTRegistration] = []
}

struct ChatGPTTokenResponse: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let token_type: String
    let expires_in: Double
    let scope: String?

    func tokens(previous: ChatGPTTokens? = nil, now: Date = Date()) throws -> ChatGPTTokens {
        guard token_type.lowercased() == "bearer", !access_token.isEmpty,
              expires_in.isFinite, expires_in > 0,
              let idToken = id_token ?? previous?.idToken, !idToken.isEmpty else {
            throw ChatGPTAuthError.message("ChatGPT returned an incomplete token response.")
        }
        // OAuth refresh may omit scope when the original grant is unchanged.
        let scopes = scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        return ChatGPTTokens(accessToken: access_token, refreshToken: refresh_token ?? previous?.refreshToken,
                             idToken: idToken, scopes: scopes, expiresAt: now.addingTimeInterval(expires_in))
    }
}

/// A single runtime owns the Keychain record and coalesces rotating-token refreshes.
public actor ChatGPTSession {
    public static let shared = ChatGPTSession()
    private let store: any ChatGPTCredentialStoring
    private let transport: any HTTPTransport
    private let verifier: any ChatGPTIdentityVerifying
    private var saved: ChatGPTSavedState?
    private var refreshes: [String: Task<String, Error>] = [:]
    private var signingIn = false
    private var signingOut: Set<String> = []
    private var catalogRequests: [String: (id: UUID, task: Task<[ChatGPTModel], Error>)] = [:]

    public init() {
        store = ChatGPTKeychainStore()
        transport = URLSession(configuration: .ephemeral, delegate: ChatGPTNoRedirects(), delegateQueue: nil)
        verifier = ChatGPTIdentityVerifier(transport: transport)
    }

    init(store: any ChatGPTCredentialStoring, transport: any HTTPTransport, verifier: any ChatGPTIdentityVerifying) {
        self.store = store; self.transport = transport; self.verifier = verifier
    }

    private func state() throws -> ChatGPTSavedState {
        if let saved { return saved }
        if let data = try store.load() { saved = try JSONDecoder().decode(ChatGPTSavedState.self, from: data) }
        else {
            let initial = ChatGPTSavedState()
            try persist(initial)
        }
        return saved!
    }

    private func persist(_ value: ChatGPTSavedState) throws {
        try store.save(JSONEncoder().encode(value))
        saved = value
    }

    public func profiles() throws -> [ChatGPTProfile] {
        try state().registrations.map {
            ChatGPTProfile(id: $0.clientID, label: $0.label, email: $0.identity?.email,
                           isSignedIn: $0.tokens != nil,
                           canUsePlan: $0.tokens?.scopes.contains(ChatGPTAuthorization.directScope) == true)
        }
    }

    public func activeProfileID() throws -> String? { try state().activeID }

    public func selectProfile(_ id: String) throws {
        var value = try state()
        guard value.registrations.contains(where: { $0.clientID == id && $0.identity != nil }) else {
            throw ChatGPTAuthError.message("Sign in to this ChatGPT connection first.")
        }
        value.activeID = id
        try persist(value)
    }

    @discardableResult
    public func signIn(profileID: String? = nil, requestConsent: Bool = false,
                       openBrowser: @escaping @MainActor @Sendable (URL) -> Bool) async throws -> String {
        guard !signingIn, signingOut.isEmpty else { throw ChatGPTAuthError.message("Another ChatGPT sign-in change is in progress.") }
        signingIn = true
        defer { signingIn = false }
        let value = try state()
        let existing = value.registrations.first { $0.clientID == profileID }
        if profileID != nil, existing == nil { throw ChatGPTAuthError.message("ChatGPT connection no longer exists.") }
        if let profileID, let refresh = refreshes[profileID] { _ = try? await refresh.value }
        let listener = ChatGPTLoopback()
        do {
            let redirect = try await listener.start()
            let attempt = try ChatGPTAuthorization(redirectURI: redirect, clientID: existing?.clientID)
            await listener.prepare(state: attempt.state)
            let url = attempt.url(hostID: value.hostID, idToken: existing?.tokens?.idToken,
                                  email: existing?.identity?.email, requestConsent: requestConsent)
            guard await openBrowser(url) else { throw ChatGPTAuthError.message("Could not open the browser for ChatGPT sign-in.") }
            let callback = try await listener.wait(state: attempt.state)
            let received = try attempt.callback(callback)
            // Retain the issued registration even if code exchange fails; never reuse the code.
            var current = try state()
            if existing == nil {
                guard !current.registrations.contains(where: { $0.clientID == received.clientID }) else {
                    throw ChatGPTAuthError.message("This registration already exists. Select its saved connection.")
                }
                current.registrations.append(ChatGPTRegistration(clientID: received.clientID,
                    label: "Connection \(current.registrations.count + 1)", identity: nil, tokens: nil))
                try persist(current)
            }
            let response = try await tokenRequest([
                "grant_type": "authorization_code", "client_id": received.clientID, "code": received.code,
                "code_verifier": attempt.verifier, "redirect_uri": redirect.absoluteString,
                "resource": ChatGPTAuthorization.resource
            ])
            guard let idToken = response.id_token else { throw ChatGPTAuthError.message("ChatGPT did not return an ID token.") }
            let identity = try await verifier.verify(idToken, clientID: received.clientID, nonce: attempt.nonce)
            if let old = existing?.identity, old.issuer != identity.issuer || old.subject != identity.subject {
                throw ChatGPTAuthError.message("The signed-in ChatGPT identity differs from the selected connection.")
            }
            let tokens = try response.tokens()
            try Task.checkCancellation()
            current = try state()
            guard let index = current.registrations.firstIndex(where: { $0.clientID == received.clientID }) else { throw CancellationError() }
            current.registrations[index].identity = identity
            current.registrations[index].tokens = tokens
            current.registrations[index].modelCatalog = nil
            invalidateCatalogRequest(received.clientID)
            current.activeID = received.clientID
            try persist(current)
            return received.clientID
        } catch {
            await listener.cancel()
            throw error
        }
    }

    public func accessToken(profileID: String) async throws -> String {
        guard !signingOut.contains(profileID),
              let record = try state().registrations.first(where: { $0.clientID == profileID }),
              record.identity != nil, let tokens = record.tokens else {
            throw ChatGPTAuthError.message("Continue with ChatGPT to sign in to this connection.")
        }
        guard tokens.scopes.contains(ChatGPTAuthorization.directScope) else {
            throw ChatGPTAuthError.message("ChatGPT plan usage is not enabled. Enable it in Account settings.")
        }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        if let task = refreshes[profileID] { return try await task.value }
        let task = Task { try await self.refresh(record) }
        refreshes[profileID] = task
        defer { refreshes[profileID] = nil }
        return try await task.value
    }

    private func refresh(_ record: ChatGPTRegistration) async throws -> String {
        guard let old = record.tokens, let refreshToken = old.refreshToken, !refreshToken.isEmpty else {
            throw ChatGPTAuthError.message("This ChatGPT connection needs a new sign-in.")
        }
        do {
            let response = try await tokenRequest(["grant_type": "refresh_token", "client_id": record.clientID,
                                                  "refresh_token": refreshToken, "resource": ChatGPTAuthorization.resource])
            if let idToken = response.id_token {
                let identity = try await verifier.verify(idToken, clientID: record.clientID, nonce: nil)
                guard identity.issuer == record.identity?.issuer, identity.subject == record.identity?.subject else {
                    throw ChatGPTAuthError.message("ChatGPT refresh returned a different identity.")
                }
            }
            let tokens = try response.tokens(previous: old)
            var value = try state()
            guard let index = value.registrations.firstIndex(where: { $0.clientID == record.clientID }),
                  value.registrations[index].tokens?.refreshToken == refreshToken else { throw CancellationError() }
            value.registrations[index].tokens = tokens
            if !tokens.scopes.contains(ChatGPTAuthorization.directScope) {
                value.registrations[index].modelCatalog = nil
                invalidateCatalogRequest(record.clientID)
            }
            try persist(value)
            guard tokens.scopes.contains(ChatGPTAuthorization.directScope) else {
                throw ChatGPTAuthError.message("ChatGPT plan permission is no longer granted. Enable it in Account settings.")
            }
            return tokens.accessToken
        } catch ChatGPTAuthError.oauth(let code) {
            if ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused"].contains(code) {
                var value = try state()
                if let index = value.registrations.firstIndex(where: { $0.clientID == record.clientID }) {
                    value.registrations[index].tokens = nil
                    value.registrations[index].modelCatalog = nil
                    invalidateCatalogRequest(record.clientID)
                    try persist(value)
                }
            }
            throw ChatGPTAuthError.oauth(code)
        }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> ChatGPTTokenResponse {
        let request = chatGPTFormRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!, fields: fields)
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InferenceClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            // Never propagate raw OAuth bodies (which can contain credentials) into UI/logs.
            let code = body?["error"] as? String ?? "http_\(http.statusCode)"
            let safe = code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            throw ChatGPTAuthError.oauth(String(safe.prefix(80)))
        }
        return try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data)
    }

    /// Display cached choices immediately, including after a restart. A catalog
    /// never grants access: inference still validates and refreshes OAuth tokens.
    public func cachedModels(profileID: String) throws -> [ChatGPTModel]? {
        try catalogRegistration(profileID).modelCatalog?.models
    }

    public func models(profileID: String, forceRefresh: Bool = false) async throws -> [ChatGPTModel] {
        let record = try catalogRegistration(profileID)
        if let current = catalogRequests[profileID] { return try await current.task.value }
        if !forceRefresh, let catalog = record.modelCatalog,
           (0..<300).contains(Date().timeIntervalSince(catalog.fetchedAt)) { return catalog.models }
        let requestID = UUID()
        let task = Task { try await self.fetchModels(profileID: profileID, requestID: requestID) }
        catalogRequests[profileID] = (requestID, task)
        defer { if catalogRequests[profileID]?.id == requestID { catalogRequests[profileID] = nil } }
        return try await task.value
    }

    private func catalogRegistration(_ profileID: String) throws -> ChatGPTRegistration {
        guard !signingOut.contains(profileID),
              let record = try state().registrations.first(where: { $0.clientID == profileID }),
              record.identity != nil, let tokens = record.tokens,
              tokens.scopes.contains(ChatGPTAuthorization.directScope) else {
            throw ChatGPTAuthError.message("Connect a ChatGPT account with plan access in Account settings.")
        }
        return record
    }

    private func invalidateCatalogRequest(_ profileID: String) {
        catalogRequests.removeValue(forKey: profileID)?.task.cancel()
    }

    private func fetchModels(profileID: String, requestID: UUID) async throws -> [ChatGPTModel] {
        let token = try await accessToken(profileID: profileID)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InferenceClientError.invalidResponse }
        guard http.statusCode == 200 else { throw ChatGPTAPIError(data: data, response: http) }
        struct Catalog: Decodable { let models: [ChatGPTModel] }
        let models = try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
        try Task.checkCancellation()
        guard catalogRequests[profileID]?.id == requestID else { throw CancellationError() }
        _ = try catalogRegistration(profileID)
        var value = try state()
        guard let index = value.registrations.firstIndex(where: { $0.clientID == profileID }) else { throw CancellationError() }
        value.registrations[index].modelCatalog = ChatGPTModelCatalog(models: models, fetchedAt: Date())
        try persist(value)
        return models
    }

    /// Returns false when local sign-out succeeded but remote revocation could not be confirmed.
    public func signOut(profileID: String) async throws -> Bool {
        guard !signingIn, !signingOut.contains(profileID) else { throw ChatGPTAuthError.message("A ChatGPT account change is already in progress.") }
        signingOut.insert(profileID)
        invalidateCatalogRequest(profileID)
        defer { signingOut.remove(profileID) }
        if let task = refreshes[profileID] { _ = try? await task.value }
        guard let record = try state().registrations.first(where: { $0.clientID == profileID }) else { return true }
        var revoked = record.tokens?.refreshToken == nil
        if let token = record.tokens?.refreshToken {
            do {
                let (data, response) = try await transport.data(for: URLRequest(url: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!))
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["issuer"] as? String == "https://auth.openai.com",
                      let endpoint = object["revocation_endpoint"] as? String, let url = URL(string: endpoint),
                      url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil else {
                    throw InferenceClientError.invalidResponse
                }
                let request = chatGPTFormRequest(url: url, fields: ["client_id": profileID, "token": token, "token_type_hint": "refresh_token"])
                for attempt in 0..<2 {
                    do {
                        let (_, result) = try await transport.data(for: request)
                        let status = (result as? HTTPURLResponse)?.statusCode ?? 0
                        revoked = status == 200
                        if revoked || (400..<500).contains(status) { break }
                    } catch { if Task.isCancelled { break } }
                    if attempt == 0 { try await Task.sleep(for: .seconds(1)) }
                }
            } catch { revoked = false }
        }
        var value = try state()
        if let index = value.registrations.firstIndex(where: { $0.clientID == profileID }) {
            value.registrations[index].tokens = nil
            value.registrations[index].modelCatalog = nil
            try persist(value)
        }
        return revoked
    }
}

final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ChatGPTAPIError: LocalizedError, Sendable {
    public let status: Int
    public let code: String?
    public let parameter: String?
    public let requestID: String?
    public let message: String
    init(status: Int, code: String?, parameter: String?, requestID: String?, message: String) {
        self.status = status; self.code = code; self.parameter = parameter
        self.requestID = requestID; self.message = message
    }
    init(data: Data, response: HTTPURLResponse) {
        status = response.statusCode
        requestID = response.value(forHTTPHeaderField: "x-request-id")
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        code = error?["code"] as? String
        parameter = error?["param"] as? String
        message = error?["message"] as? String ?? object?["detail"] as? String ?? "HTTP \(response.statusCode)"
    }
    public var errorDescription: String? {
        var text = "ChatGPT plan: \(message)"
        if let code { text += " (\(code))" }
        if code == "subscription_sharing_usage_limit_exceeded" { text += " Manage usage in ChatGPT settings before trying again." }
        if let requestID { text += " Request ID: \(requestID)" }
        return text
    }
}
