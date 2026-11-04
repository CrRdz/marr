import CryptoKit
import Foundation
import Security

public enum ChatGPTAuthError: LocalizedError, Equatable, Sendable {
    case message(String)
    case oauth(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .oauth(let code): "ChatGPT authorization failed (\(code)). Please sign in again."
        }
    }
}

struct ChatGPTIdentity: Codable, Equatable, Sendable {
    let issuer: String
    let subject: String
    let email: String?
}

protocol ChatGPTIdentityVerifying: Sendable {
    func verify(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity
}

struct ChatGPTIdentityVerifier: ChatGPTIdentityVerifying {
    let transport: any HTTPTransport

    func verify(_ token: String, clientID: String, nonce: String?) async throws -> ChatGPTIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let claimsData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let kid = header["kid"] as? String,
              let alg = header["alg"] as? String, ["RS256", "ES256"].contains(alg) else {
            throw ChatGPTAuthError.message("ChatGPT returned an invalid ID token.")
        }
        let (data, response) = try await transport.data(for: URLRequest(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let jwks = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid }),
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == alg else {
            throw ChatGPTAuthError.message("Could not verify the ChatGPT signing key. Try again.")
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard try Self.verifySignature(signature, message: signed, key: key, algorithm: alg) else {
            throw ChatGPTAuthError.message("ChatGPT ID token signature validation failed.")
        }
        return try Self.validateClaims(claimsData, clientID: clientID, nonce: nonce, now: Date())
    }

    static func validateClaims(_ data: Data, clientID: String, nonce: String?, now: Date) throws -> ChatGPTIdentity {
        guard let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let issued = claims["iat"] as? Double, issued <= now.timeIntervalSince1970 + 60 else {
            throw ChatGPTAuthError.message("ChatGPT ID token identity or expiry is invalid.")
        }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID),
              audience.count <= 1 || claims["azp"] as? String == clientID,
              claims["azp"] == nil || claims["azp"] as? String == clientID,
              nonce == nil || claims["nonce"] as? String == nonce,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60 else {
            throw ChatGPTAuthError.message("ChatGPT ID token audience or nonce did not match this sign-in.")
        }
        return ChatGPTIdentity(issuer: "https://auth.openai.com", subject: subject, email: claims["email"] as? String)
    }

    static func verifySignature(_ signature: Data, message: Data, key: [String: Any], algorithm: String) throws -> Bool {
        if algorithm == "ES256", key["kty"] as? String == "EC", key["crv"] as? String == "P-256",
           let x = key["x"] as? String, let y = key["y"] as? String,
           let xd = Data(base64URL: x), let yd = Data(base64URL: y), xd.count == 32, yd.count == 32 {
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + xd + yd)
            return publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message)
        }
        guard algorithm == "RS256", key["kty"] as? String == "RSA",
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = Data(base64URL: n), modulus.count >= 256,
              let exponent = Data(base64URL: e) else { return false }
        func der(_ tag: UInt8, _ value: Data) -> Data {
            var length = value.count
            var bytes = [UInt8]()
            repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
            let prefix: [UInt8] = value.count < 128 ? [UInt8(value.count)] : [0x80 | UInt8(bytes.count)] + bytes
            return Data([tag] + prefix) + value
        }
        func integer(_ bytes: Data) -> Data {
            var value = Data(bytes.drop(while: { $0 == 0 }))
            if value.isEmpty { value = Data([0]) }
            if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
            return der(2, value)
        }
        let encoded = der(0x30, integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(encoded as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }
}

extension Data {
    init?(base64URL: String) {
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
