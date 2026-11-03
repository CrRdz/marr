import CryptoKit
import Foundation
import MarrCore
import Security
@testable import MarrNetworking
import Testing

@Suite("ChatGPT plan OAuth")
struct ChatGPTAuthTests {
    @Test("Dynamic authorization uses fresh PKCE, identity scopes and the stable host")
    func authorization() throws {
        let redirect = URL(string: "http://127.0.0.1:1455/auth/callback")!
        let first = try ChatGPTAuthorization(redirectURI: redirect, clientID: nil)
        let second = try ChatGPTAuthorization(redirectURI: redirect, clientID: nil)
        let items = query(first.url(hostID: "urn:uuid:host", idToken: nil, email: nil, requestConsent: false))
        #expect(items["client_id"] == "dynamic_agent_client")
        #expect(items["agent_name_hint"] == "Marr")
        #expect(items["ext_agent_host_id"] == "urn:uuid:host")
        #expect(items["resource"] == "https://api.openai.com/v1")
        #expect(items["scope"]?.contains("chatgpt.tokens.use.direct") == true)
        #expect(items["code_challenge"] == Data(SHA256.hash(data: Data(first.verifier.utf8))).base64URL)
        #expect(first.verifier.count == 43)
        #expect(first.state != second.state && first.nonce != second.nonce && first.verifier != second.verifier)
        #expect(items["client_secret"] == nil && items["prompt"] == nil)
    }

    @Test("Returning registration reuses issued ID and sends consent only when requested")
    func reauthorization() throws {
        let attempt = try ChatGPTAuthorization(redirectURI: callbackURL, clientID: "oaiapp_saved")
        let items = query(attempt.url(hostID: "host", idToken: "hint", email: "a+b@example.com", requestConsent: true))
        #expect(items["client_id"] == "oaiapp_saved")
        #expect(items["agent_name_hint"] == nil)
        #expect(items["id_token_hint"] == "hint")
        #expect(items["login_hint"] == "a+b@example.com")
        #expect(items["prompt"] == "consent")
        let result = try attempt.callback(callback(attempt, values: ["code": "code"]))
        #expect(result.clientID == "oaiapp_saved")
        #expect(throws: (any Error).self) { try attempt.callback(callback(attempt, values: ["code": "code", "client_id": "different"])) }
    }

    @Test("Rejects missing issued IDs, wrong state, duplicate params, expiry and declined consent")
    func callbackValidation() throws {
        let attempt = try ChatGPTAuthorization(redirectURI: callbackURL, clientID: nil)
        let good = callback(attempt, values: ["code": "code", "client_id": "oaiapp_issued"])
        #expect(try attempt.callback(good).clientID == "oaiapp_issued")
        for values in [["code": "code"], ["code": "code", "client_id": "dynamic_agent_client"],
                       ["code": "code", "client_id": "ok", "state": "wrong"], ["error": "access_denied"]] {
            #expect(throws: (any Error).self) { try attempt.callback(callback(attempt, values: values)) }
        }
        #expect(throws: (any Error).self) { try attempt.callback(URL(string: good.absoluteString + "&state=duplicate")!) }
        #expect(throws: (any Error).self) { try attempt.callback(good, now: attempt.expiresAt) }
        #expect(throws: (any Error).self) { try attempt.callback(URL(string: good.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!) }
    }

    @Test("OIDC claims reject wrong issuer, audience, nonce, expiry and authorized party")
    func claims() throws {
        let now = Date()
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "subject", "aud": "client",
                                    "nonce": "nonce", "iat": now.timeIntervalSince1970 - 10, "exp": now.timeIntervalSince1970 + 300]
        #expect(try ChatGPTIdentityVerifier.validateClaims(JSONSerialization.data(withJSONObject: claims), clientID: "client", nonce: "nonce", now: now).subject == "subject")
        let changes: [[String: Any]] = [["iss": "https://evil.example"], ["aud": "other"], ["nonce": "other"],
                                       ["exp": 0], ["iat": now.timeIntervalSince1970 + 3600], ["aud": ["client", "other"]], ["azp": "other"]]
        for change in changes {
            let altered = claims.merging(change) { _, new in new }
            #expect(throws: (any Error).self) { try ChatGPTIdentityVerifier.validateClaims(JSONSerialization.data(withJSONObject: altered), clientID: "client", nonce: "nonce", now: now) }
        }
    }

    @Test("JWKS signature verification rejects tampering")
    func signedIdentity() async throws {
        let key = P256.Signing.PrivateKey()
        let raw = key.publicKey.x963Representation
        let jwk: [String: Any] = ["kid": "test", "alg": "ES256", "kty": "EC", "crv": "P-256", "use": "sig",
                                  "x": Data(raw[1..<33]).base64URL, "y": Data(raw[33..<65]).base64URL]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "test"]).base64URL
        let claims = try JSONSerialization.data(withJSONObject: ["iss": "https://auth.openai.com", "sub": "verified",
            "aud": "client", "nonce": "nonce", "iat": Date().timeIntervalSince1970, "exp": Date().timeIntervalSince1970 + 300] as [String: Any]).base64URL
        let message = Data("\(header).\(claims)".utf8)
        let signature = try key.signature(for: message).rawRepresentation.base64URL
        let transport = OAuthTransport(responses: [try JSONSerialization.data(withJSONObject: ["keys": [jwk]]), try JSONSerialization.data(withJSONObject: ["keys": [jwk]])])
        let verifier = ChatGPTIdentityVerifier(transport: transport)
        let identity = try await verifier.verify("\(header).\(claims).\(signature)", clientID: "client", nonce: "nonce")
        #expect(identity.subject == "verified")
        let badSignature = Data(repeating: 1, count: 64).base64URL
        await #expect(throws: (any Error).self) { try await verifier.verify("\(header).\(claims).\(badSignature)", clientID: "client", nonce: "nonce") }
    }

    @Test("RSA JWKS keys verify RS256 signatures and reject modified messages")
    func rsaSignature() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Decode the PKCS#1 sequence emitted by Security for the test's JWK.
        var offset = 0
        func read() -> Data {
            offset += 1
            var length = Int(der[offset]); offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f; length = 0
                for _ in 0..<count { length = length * 256 + Int(der[offset]); offset += 1 }
            }
            let result = Data(der[offset..<(offset + length)]); offset += length
            return result
        }
        let sequence = read()
        let bytes = [UInt8](sequence)
        func integer(at start: inout Int) -> Data {
            start += 1
            var length = Int(bytes[start]); start += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f; length = 0
                for _ in 0..<count { length = length * 256 + Int(bytes[start]); start += 1 }
            }
            let value = Data(bytes[start..<(start + length)].drop(while: { $0 == 0 })); start += length
            return value
        }
        var cursor = 0
        let modulus = integer(at: &cursor), exponent = integer(at: &cursor)
        let jwk: [String: Any] = ["kty": "RSA", "n": modulus.base64URL, "e": exponent.base64URL]
        let message = Data("signed message".utf8)
        let signature = try #require(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)) as Data
        #expect(try ChatGPTIdentityVerifier.verifySignature(signature, message: message, key: jwk, algorithm: "RS256"))
        #expect(try !ChatGPTIdentityVerifier.verifySignature(signature, message: Data("tampered".utf8), key: jwk, algorithm: "RS256"))
    }

    @Test("Missing direct grant is preserved as identity-only and never authorizes inference")
    func missingPermission() async throws {
        let store = try fixture(scopes: ["openid"])
        let transport = OAuthTransport(responses: [])
        let session = makeSession(store, transport)
        #expect(try await session.profiles().first?.isSignedIn == true)
        #expect(try await session.profiles().first?.canUsePlan == false)
        await #expect(throws: (any Error).self) { try await session.accessToken(profileID: "client") }
        #expect(await transport.requests.isEmpty)
    }

    @Test("Concurrent expired access coalesces refresh and atomically saves rotated credentials")
    func refreshRotation() async throws {
        let store = try fixture(expired: true)
        let transport = OAuthTransport(responses: [tokenResponse(access: "new-access", refresh: "rotated")], delay: true)
        let session = makeSession(store, transport)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 { group.addTask { try await session.accessToken(profileID: "client") } }
            var result: [String] = []
            for try await token in group { result.append(token) }
            return result
        }
        #expect(tokens.count == 12 && tokens.allSatisfy { $0 == "new-access" })
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = String(decoding: requests[0].httpBody!, as: UTF8.self)
        #expect(body.contains("client_id=client") && body.contains("refresh_token=refresh"))
        #expect(!body.contains("scope=") && !body.contains("client_secret"))
        let restored = makeSession(store, OAuthTransport(responses: []))
        #expect(try await restored.accessToken(profileID: "client") == "new-access")
        let state = try JSONDecoder().decode(ChatGPTSavedState.self, from: store.load()!)
        #expect(state.registrations[0].tokens?.refreshToken == "rotated")
        #expect(state.registrations[0].tokens?.scopes.contains(ChatGPTAuthorization.directScope) == true)
    }

    @Test("Terminal refresh clears credentials; transient errors preserve them")
    func refreshErrors() async throws {
        for code in ["invalid_grant", "temporarily_unavailable"] {
            let store = try fixture(expired: true)
            let session = makeSession(store, OAuthTransport(responses: [Data("{\"error\":\"\(code)\"}".utf8)], status: 400))
            await #expect(throws: (any Error).self) { try await session.accessToken(profileID: "client") }
            let state = try JSONDecoder().decode(ChatGPTSavedState.self, from: store.load()!)
            #expect((state.registrations[0].tokens == nil) == (code == "invalid_grant"))
            #expect(state.registrations[0].clientID == "client")
            #expect(state.registrations[0].identity?.subject == "subject")
        }
    }

    @Test("Revocation uses discovered endpoint, clears all tokens, retains host and registration")
    func signOut() async throws {
        let store = try fixture()
        let transport = OAuthTransport(responses: [Data(#"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/oauth/revoke"}"#.utf8), Data()])
        let session = makeSession(store, transport)
        #expect(try await session.signOut(profileID: "client"))
        let saved = try JSONDecoder().decode(ChatGPTSavedState.self, from: store.load()!)
        #expect(saved.hostID == "urn:uuid:test")
        #expect(saved.activeID == "client" && saved.registrations[0].tokens == nil)
        let requests = await transport.requests
        let body = String(decoding: requests[1].httpBody!, as: UTF8.self)
        #expect(body.contains("token_type_hint=refresh_token") && body.contains("client_id=client"))
    }

    @Test("Models use the OAuth token and preserve visible catalog ordering")
    func modelDiscovery() async throws {
        let transport = OAuthTransport(responses: [Data(#"{"models":[{"slug":"first","display_name":"First","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"second","display_name":"Second","visibility":"list"}]}"#.utf8)])
        let session = makeSession(try fixture(), transport)
        #expect(try await session.models(profileID: "client").map(\.slug) == ["first", "second"])
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test("Model catalogs coalesce requests and survive a runtime restart")
    func modelCatalogCache() async throws {
        let store = try fixture()
        let transport = OAuthTransport(responses: [modelCatalog("first"), modelCatalog("updated")], delay: true)
        let session = makeSession(store, transport)
        #expect(try await session.cachedModels(profileID: "client") == nil)
        try await withThrowingTaskGroup(of: [ChatGPTModel].self) { group in
            for _ in 0..<12 { group.addTask { try await session.models(profileID: "client") } }
            for try await models in group { #expect(models.map(\.slug) == ["first"]) }
        }
        #expect(await transport.requests.count == 1)
        #expect(try await session.models(profileID: "client").map(\.slug) == ["first"])
        #expect(await transport.requests.count == 1)
        let noNetwork = OAuthTransport(responses: [])
        let restarted = makeSession(store, noNetwork)
        #expect(try await restarted.cachedModels(profileID: "client")?.map(\.slug) == ["first"])
        #expect(try await restarted.models(profileID: "client").map(\.slug) == ["first"])
        #expect(await noNetwork.requests.isEmpty)
        #expect(try await session.models(profileID: "client", forceRefresh: true).map(\.slug) == ["updated"])
        #expect(await transport.requests.count == 2)
    }

    @Test("A failed refresh keeps stale choices, and sign-out removes the cached catalog")
    func staleCatalog() async throws {
        let store = try fixture()
        var saved = try JSONDecoder().decode(ChatGPTSavedState.self, from: store.load()!)
        let models = try JSONDecoder().decode([ChatGPTModel].self,
            from: Data(#"[{"slug":"cached","display_name":"Cached","visibility":"list"}]"#.utf8))
        saved.registrations[0].modelCatalog = ChatGPTModelCatalog(models: models, fetchedAt: Date().addingTimeInterval(-600))
        store.save(try JSONEncoder().encode(saved))
        let transport = OAuthTransport(responses: [Data("{}".utf8)], status: 503)
        let session = makeSession(store, transport)
        #expect(try await session.cachedModels(profileID: "client")?.map(\.slug) == ["cached"])
        await #expect(throws: (any Error).self) { try await session.models(profileID: "client") }
        #expect(await transport.requests.count == 1)
        #expect(try await session.cachedModels(profileID: "client")?.map(\.slug) == ["cached"])
        _ = try await session.signOut(profileID: "client")
        await #expect(throws: (any Error).self) { try await session.cachedModels(profileID: "client") }
        let signedOut = try JSONDecoder().decode(ChatGPTSavedState.self, from: store.load()!)
        #expect(signedOut.registrations[0].modelCatalog == nil)
    }

    @Test("Catalogs remain isolated by OAuth registration")
    func catalogAccountIsolation() async throws {
        let store = try fixture()
        var saved = try JSONDecoder().decode(ChatGPTSavedState.self, from: store.load()!)
        let original = saved.registrations[0]
        saved.registrations.append(.init(clientID: "other", label: "Other", identity: original.identity, tokens: original.tokens))
        store.save(try JSONEncoder().encode(saved))
        let transport = OAuthTransport(responses: [modelCatalog("personal"), modelCatalog("workspace")])
        let session = makeSession(store, transport)
        _ = try await session.models(profileID: "client")
        #expect(try await session.cachedModels(profileID: "other") == nil)
        try await session.selectProfile("other")
        #expect(try await session.models(profileID: "other").map(\.slug) == ["workspace"])
        #expect(try await session.cachedModels(profileID: "client")?.map(\.slug) == ["personal"])
        #expect(await transport.requests.count == 2)
    }

    private func modelCatalog(_ slug: String) -> Data {
        Data("{\"models\":[{\"slug\":\"\(slug)\",\"display_name\":\"\(slug)\",\"visibility\":\"list\"}]}".utf8)
    }

    @Test("Model reasoning levels use advertised metadata or conservative known defaults")
    func modelReasoningLevels() throws {
        let models = try JSONDecoder().decode([ChatGPTModel].self, from: Data(#"""
        [
          {"slug":"gpt-6.1-sol","display_name":"Sol","visibility":"list"},
          {"slug":"custom-model","display_name":"Custom","visibility":"list","supported_reasoning_efforts":["low","high"]},
          {"slug":"nonreasoning","display_name":"Classic","visibility":"list"}
        ]
        """#.utf8))
        #expect(models[0].reasoningEfforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(models[0].supportsFastMode)
        #expect(models[1].reasoningEfforts == ["low", "high"])
        #expect(!models[1].supportsFastMode)
        #expect(models[2].reasoningEfforts.isEmpty)
    }

    @Test("Plan requests pin the public route, force streaming and never persist responses")
    @MainActor func inference() async throws {
        let transport = OAuthTransport(responses: [completedStream])
        let session = makeSession(try fixture(), OAuthTransport(responses: []))
        var connection = InferenceConnection.chatGPT(profileID: "client")
        connection.baseURL = "https://untrusted.example"
        connection.customHeaders = ["Authorization": "malicious", "X-Secret": "not-for-openai"]
        connection.apiFormat = .anthropicMessages
        connection.reasoningEffort = "high"
        connection.fastMode = true
        let response = try await InferenceClient(transport: transport, chatGPTSession: session).askWithUsage(request: visionRequest, model: "eligible", connection: connection)
        #expect(response.text == "hello")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "X-Secret") == nil)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "eligible")
        #expect((body["reasoning"] as? [String: String])?["effort"] == "high")
        #expect(body["service_tier"] as? String == "fast")
    }

    @Test("Partial streams and JSON fallback cannot report successful plan inference")
    @MainActor func interruptedStream() async throws {
        for data in [Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".utf8),
                     Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"hello"}]}]}"#.utf8)] {
            let transport = OAuthTransport(responses: [data])
            let client = InferenceClient(transport: transport, chatGPTSession: makeSession(try fixture(), OAuthTransport(responses: [])))
            await #expect(throws: InferenceClientError.incompleteStream) {
                try await client.askWithUsage(request: visionRequest, model: "model", connection: .chatGPT(profileID: "client"))
            }
        }
    }

    @Test("Usage-limit errors do not retry or switch billing paths")
    @MainActor func usageLimit() async throws {
        let data = Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"App limit reached"}}"#.utf8)
        let transport = OAuthTransport(responses: [data], status: 429)
        let client = InferenceClient(transport: transport, chatGPTSession: makeSession(try fixture(), OAuthTransport(responses: [])), retrySleep: { _ in Issue.record("Must not retry usage limit") })
        do {
            _ = try await client.askWithUsage(request: visionRequest, model: "model", connection: .chatGPT(profileID: "client"))
            Issue.record("Expected usage error")
        } catch let error as ChatGPTAPIError {
            #expect(error.code == "subscription_sharing_usage_limit_exceeded")
            #expect(error.status == 429 && error.requestID == "request-test")
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("Browser callback exchanges the issued ID and saves only the token response grant", arguments: [true, false])
    @MainActor func browserRoundTrip(granted: Bool) async throws {
        let store = OAuthMemoryStore()
        let data = try JSONSerialization.data(withJSONObject: ["access_token": "access", "refresh_token": "refresh",
            "id_token": "id", "token_type": "Bearer", "expires_in": 3600,
            "scope": granted ? "openid chatgpt.tokens.use.direct" : "openid"] as [String: Any])
        let transport = OAuthTransport(responses: [data])
        let session = makeSession(store, transport)
        let task = Task {
            try await session.signIn { authorizationURL in
                let params = query(authorizationURL)
                var callback = URLComponents(string: params["redirect_uri"]!)!
                callback.queryItems = [URLQueryItem(name: "state", value: params["state"]),
                                       URLQueryItem(name: "client_id", value: "oaiapp_issued"),
                                       URLQueryItem(name: "scope", value: "chatgpt.tokens.use.direct"),
                                       URLQueryItem(name: "code", value: "single-use-code")]
                let url = callback.url!
                Task { _ = try? await URLSession.shared.data(from: url) }
                return true
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { task.cancel() }
        }
        defer { deadline.cancel() }
        #expect(try await task.value == "oaiapp_issued")
        #expect(try await session.activeProfileID() == "oaiapp_issued")
        #expect(try await session.profiles().first?.canUsePlan == granted)
        let request = try #require(await transport.requests.first)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("client_id=oaiapp_issued"))
        #expect(body.contains("code_verifier="))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A"))
        #expect(!body.contains("dynamic_agent_client") && !body.contains("client_secret"))
    }

    @Test("Cancelling browser sign-in releases the loopback listener and preserves the active account")
    @MainActor func cancellation() async throws {
        let session = makeSession(try fixture(), OAuthTransport(responses: []))
        let task = Task {
            try await session.signIn(openBrowser: { _ in true })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await session.activeProfileID() == "client")
        #expect(try await session.accessToken(profileID: "client") == "access")
    }

    @Test("Usage failure after streamed text preserves structured diagnostics and cannot succeed")
    @MainActor func streamingUsageFailure() async throws {
        let data = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"Limit reached\"}}}\n\n".utf8)
        let transport = OAuthTransport(responses: [data])
        let client = InferenceClient(transport: transport, chatGPTSession: makeSession(try fixture(), OAuthTransport(responses: [])))
        do {
            _ = try await client.askWithUsage(request: visionRequest, model: "model", connection: .chatGPT(profileID: "client"))
            Issue.record("Expected stream failure")
        } catch let error as ChatGPTAPIError {
            #expect(error.code == "subscription_sharing_usage_limit_exceeded")
            #expect(error.requestID == "request-test")
            #expect(error.status == 200)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("Form encoding round-trips reserved characters")
    func formEncoding() {
        let request = chatGPTFormRequest(url: callbackURL, fields: ["code": "a+b&c=d /", "client_id": "issued"])
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body == "client_id=issued&code=a%2Bb%26c%3Dd%20%2F")
    }

    private var callbackURL: URL { URL(string: "http://127.0.0.1:1455/auth/callback")! }
    private var visionRequest: VisionRequest { .init(systemPrompt: "system", messages: [.init(role: .user, content: [.text("hello")])]) }
    private var completedStream: Data { Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"hello\"}]}]}}\n\n".utf8) }
    private func query(_ url: URL) -> [String: String] { Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }) }
    private func callback(_ attempt: ChatGPTAuthorization, values: [String: String]) -> URL {
        var components = URLComponents(url: attempt.redirectURI, resolvingAgainstBaseURL: false)!
        components.queryItems = ["state": attempt.state].merging(values) { _, new in new }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
    private func fixture(expired: Bool = false, scopes: [String] = ["openid", "chatgpt.tokens.use.direct"]) throws -> OAuthMemoryStore {
        var state = ChatGPTSavedState()
        state.hostID = "urn:uuid:test"; state.activeID = "client"
        state.registrations = [.init(clientID: "client", label: "Connection 1", identity: .init(issuer: "https://auth.openai.com", subject: "subject", email: "a@example.com"),
                                     tokens: .init(accessToken: "access", refreshToken: "refresh", idToken: "id", scopes: scopes, expiresAt: Date().addingTimeInterval(expired ? -10 : 3600)))]
        return OAuthMemoryStore(data: try JSONEncoder().encode(state))
    }
    private func makeSession(_ store: OAuthMemoryStore, _ transport: OAuthTransport) -> ChatGPTSession {
        ChatGPTSession(store: store, transport: transport, verifier: OAuthTestVerifier())
    }
    private func tokenResponse(access: String, refresh: String) -> Data {
        Data("{\"access_token\":\"\(access)\",\"refresh_token\":\"\(refresh)\",\"token_type\":\"Bearer\",\"expires_in\":3600}".utf8)
    }
}

private final class OAuthMemoryStore: ChatGPTCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() -> Data? { lock.withLock { data } }
    func save(_ data: Data) { lock.withLock { self.data = data } }
}

private actor OAuthTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [Data]
    let status: Int
    let delay: Bool
    init(responses: [Data], status: Int = 200, delay: Bool = false) { self.responses = responses; self.status = status; self.delay = delay }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let data = responses.removeFirst()
        if delay { try await Task.sleep(for: .milliseconds(30)) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["x-request-id": "request-test"])!)
    }
}

private struct OAuthTestVerifier: ChatGPTIdentityVerifying {
    func verify(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        .init(issuer: "https://auth.openai.com", subject: "subject", email: "a@example.com")
    }
}
