import CryptoKit
import Foundation
import Security

struct ChatGPTAuthorization: Sendable {
    static let resource = "https://api.openai.com/v1"
    static let directScope = "chatgpt.tokens.use.direct"
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: URL
    let clientID: String?
    let expiresAt: Date

    init(redirectURI: URL, clientID: String?) throws {
        self.redirectURI = redirectURI
        self.clientID = clientID
        state = try Self.random()
        nonce = try Self.random()
        verifier = try Self.random()
        expiresAt = Date().addingTimeInterval(300)
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTAuthError.message("Could not generate a secure sign-in request.")
        }
        return Data(bytes).base64URL
    }

    func url(hostID: String, idToken: String?, email: String?, requestConsent: Bool) -> URL {
        var fields = [
            "client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
            "response_type": "code", "redirect_uri": redirectURI.absoluteString,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": Self.resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        ]
        if clientID == nil { fields["agent_name_hint"] = "Marr" }
        else { fields["id_token_hint"] = idToken; fields["login_hint"] = email }
        if requestConsent { fields["prompt"] = "consent" }
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    func callback(_ url: URL, now: Date = Date()) throws -> (code: String, clientID: String) {
        guard now < expiresAt, url.scheme == redirectURI.scheme, url.host == "127.0.0.1",
              url.port == redirectURI.port, url.path == redirectURI.path,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw ChatGPTAuthError.message("Sign-in callback did not match this request. Please try again.")
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        if values["error"] != nil { throw ChatGPTAuthError.message("ChatGPT sign-in was declined or could not be completed.") }
        guard let code = values["code"], !code.isEmpty,
              let issuedID = values["client_id"] ?? clientID, !issuedID.isEmpty, issuedID != "dynamic_agent_client",
              clientID == nil || issuedID == clientID else {
            throw ChatGPTAuthError.message("ChatGPT registration did not return the expected client ID.")
        }
        return (code, issuedID)
    }
}

func chatGPTFormRequest(url: URL, fields: [String: String]) -> URLRequest {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let body = fields.sorted { $0.key < $1.key }.map {
        "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(body.utf8)
    return request
}
