import Foundation
import Security
import Synchronization
@testable import LiveMinutesKit

/// テストの中で作る RSA の鍵。ID トークンへの署名と、JWKS の応答に使う（秘密をソースに置かない）。
struct TestRSAKey: @unchecked Sendable {
    // @unchecked の理由: SecKey は作った後に変更しない不変のオブジェクトで、Security.framework はスレッドセーフ。
    let privateKey: SecKey
    let kid: String

    init(kid: String = "test-key-1") throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        privateKey = key
        self.kid = kid
    }

    /// JWK（公開鍵）。PKCS#1 の DER から n と e を取り出す
    var jwk: [String: String] {
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let der = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        let (modulus, exponent) = Self.parseRSAPublicKey(der)
        return [
            "kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
            "n": OAuthEncoding.base64URL(modulus), "e": OAuthEncoding.base64URL(exponent),
        ]
    }

    static func jwksJSON(_ keys: [TestRSAKey]) -> String {
        let object: [String: Any] = ["keys": keys.map(\.jwk)]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// JWT を作る。`alg` を変えると、署名の方式を偽ったトークンになる
    func sign(payload: [String: Any], alg: String = "RS256", kid: String? = nil) -> String {
        let header: [String: Any] = ["alg": alg, "typ": "JWT", "kid": kid ?? self.kid]
        let headerPart = OAuthEncoding.base64URL(try! JSONSerialization.data(withJSONObject: header))
        let payloadPart = OAuthEncoding.base64URL(try! JSONSerialization.data(withJSONObject: payload))
        let input = Data("\(headerPart).\(payloadPart)".utf8)
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)! as Data
        return "\(headerPart).\(payloadPart).\(OAuthEncoding.base64URL(signature))"
    }

    /// RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER } を読む（テスト用の最小限）
    static func parseRSAPublicKey(_ der: Data) -> (Data, Data) {
        var index = der.startIndex
        func readLength() -> Int {
            let first = der[index]
            index += 1
            guard first & 0x80 != 0 else { return Int(first) }
            var length = 0
            for _ in 0..<Int(first & 0x7F) {
                length = (length << 8) | Int(der[index])
                index += 1
            }
            return length
        }
        func readInteger() -> Data {
            precondition(der[index] == 0x02)
            index += 1
            let length = readLength()
            let value = der[index..<(index + length)]
            index += length
            return Data(value)
        }
        precondition(der[index] == 0x30)
        index += 1
        _ = readLength()
        return (readInteger(), readInteger())
    }
}

/// 手で進める壁時計。
final class TestWallClock: Sendable {
    private let current: Mutex<Date>

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(date)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// ChatGPT の認証サーバーのスタブ（token・revoke・jwks を別々の URL に登録する）。
struct ChatGPTStubServer {
    let endpoints: ChatGPTAuth.Endpoints
    let tokenURL: URL
    let revokeURL: URL
    let jwksURL: URL

    static let issuer = "https://auth.openai.com"

    init(
        token: @escaping StubURLProtocol.Handler,
        revoke: @escaping StubURLProtocol.Handler = { _ in .http(status: 200, chunks: []) },
        jwks: @escaping StubURLProtocol.Handler
    ) {
        tokenURL = StubURLProtocol.register(token)
        revokeURL = StubURLProtocol.register(revoke)
        jwksURL = StubURLProtocol.register(jwks)
        endpoints = ChatGPTAuth.Endpoints(
            issuer: Self.issuer,
            authorize: URL(string: "https://auth.invalid/api/accounts/authorize")!,
            token: tokenURL,
            revoke: revokeURL,
            jwks: jwksURL
        )
    }

    var tokenRequests: [StubURLProtocol.RecordedRequest] { StubURLProtocol.requests(for: tokenURL) }
    var revokeRequests: [StubURLProtocol.RecordedRequest] { StubURLProtocol.requests(for: revokeURL) }
    var jwksRequests: [StubURLProtocol.RecordedRequest] { StubURLProtocol.requests(for: jwksURL) }
}

enum ChatGPTFixtures {
    static let clientID = "oaiapp_test_client"
    static let subject = "user-sub-1"
    static let fullScope = "chatgpt.tokens.use.direct email offline_access openid profile resource.invoke"

    static func record(
        accessToken: String = "access-1",
        refreshToken: String = "refresh-1",
        expiresAt: Date,
        scopes: [String] = fullScope.split(separator: " ").map(String.init),
        subject: String = subject
    ) -> ChatGPTCredentialRecord {
        ChatGPTCredentialRecord(
            clientID: clientID,
            subject: subject,
            email: "user@example.com",
            idToken: "old-id-token",
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: expiresAt,
            earliestRefreshAt: nil,
            scopes: scopes
        )
    }

    static func tokenJSON(
        accessToken: String = "access-2",
        refreshToken: String? = "refresh-2",
        idToken: String? = nil,
        scope: String? = fullScope,
        expiresIn: Int = 3600
    ) -> String {
        var object: [String: Any] = ["access_token": accessToken, "token_type": "Bearer", "expires_in": expiresIn]
        if let refreshToken { object["refresh_token"] = refreshToken }
        if let idToken { object["id_token"] = idToken }
        if let scope { object["scope"] = scope }
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    static func formFields(_ request: StubURLProtocol.RecordedRequest) -> [String: String] {
        var result: [String: String] = [:]
        for pair in request.bodyString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }
}
