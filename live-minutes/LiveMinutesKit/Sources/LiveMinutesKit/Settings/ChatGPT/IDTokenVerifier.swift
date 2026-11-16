import Foundation
import Security

/// ID トークンの検証で確かめた内容。
struct IDTokenClaims: Equatable, Sendable {
    let subject: String
    let email: String?
}

/// ID トークンの検証の失敗。中身（トークンや値）は持たない。
public enum IDTokenError: Error, Equatable, Sendable {
    case malformed
    case unsupportedAlgorithm
    case unknownKey
    case invalidSignature
    case issuerMismatch
    case audienceMismatch
    case expired
    case nonceMismatch
    case missingSubject
}

/// ID トークン（JWT）を OpenAI の JWKS で検証する（DESIGN.md §4.11 手順6）。
///
/// - `alg` は RS256 だけを受け付ける（`none` や HS256 は拒否する）
/// - 鍵は JWK の `n` と `e` から PKCS#1 の DER を組み立て、Security.framework で作る（CryptoKit には RSA がない）
/// - クレームは `iss`、`aud`（文字列か配列）、`exp`（60秒の許容）、`nonce` を確かめる
enum IDTokenVerifier {
    static let clockSkew: TimeInterval = 60

    /// JWT の各部分
    struct Parts {
        let header: Header
        let payload: Payload
        let signingInput: Data
        let signature: Data
    }

    struct Header: Decodable {
        let alg: String?
        let kid: String?
    }

    struct Payload: Decodable {
        let iss: String?
        let aud: Audience?
        let exp: Double?
        let nonce: String?
        let sub: String?
        let email: String?
    }

    /// `aud` は文字列か文字列の配列
    struct Audience: Decodable {
        let values: [String]

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                values = [single]
            } else {
                values = try container.decode([String].self)
            }
        }
    }

    static func split(_ token: String) throws -> Parts {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let headerData = OAuthEncoding.decodeBase64URL(pieces[0]),
              let payloadData = OAuthEncoding.decodeBase64URL(pieces[1]),
              let signature = OAuthEncoding.decodeBase64URL(pieces[2]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else {
            throw IDTokenError.malformed
        }
        return Parts(header: header, payload: payload, signingInput: Data("\(pieces[0]).\(pieces[1])".utf8), signature: signature)
    }

    /// 署名を確かめる。`key` は `kid` に対応する公開鍵
    static func verifySignature(_ parts: Parts, key: SecKey) throws {
        guard parts.header.alg == "RS256" else { throw IDTokenError.unsupportedAlgorithm }
        var error: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            parts.signingInput as CFData,
            parts.signature as CFData,
            &error
        )
        error?.release()
        guard valid else { throw IDTokenError.invalidSignature }
    }

    /// クレームを確かめる。
    static func verifyClaims(_ payload: Payload, issuer: String, clientID: String, nonce: String, now: Date) throws -> IDTokenClaims {
        guard payload.iss == issuer else { throw IDTokenError.issuerMismatch }
        guard payload.aud?.values.contains(clientID) == true else { throw IDTokenError.audienceMismatch }
        guard let exp = payload.exp, Date(timeIntervalSince1970: exp + clockSkew) > now else { throw IDTokenError.expired }
        guard payload.nonce == nonce else { throw IDTokenError.nonceMismatch }
        guard let subject = payload.sub, !subject.isEmpty else { throw IDTokenError.missingSubject }
        return IDTokenClaims(subject: subject, email: payload.email)
    }

    // MARK: - JWKS

    struct KeySet: Decodable {
        struct Key: Decodable {
            let kty: String?
            let kid: String?
            let use: String?
            let alg: String?
            let n: String?
            let e: String?
        }

        let keys: [Key]
    }

    /// JWKS から RSA の公開鍵を作る（`kid` ごと）。署名用でない鍵や RSA でない鍵は飛ばす。
    static func publicKeys(from data: Data) throws -> [String: SecKey] {
        guard let set = try? JSONDecoder().decode(KeySet.self, from: data) else { throw IDTokenError.malformed }
        var result: [String: SecKey] = [:]
        for key in set.keys {
            guard key.kty == "RSA", key.use == nil || key.use == "sig",
                  let kid = key.kid, let n = key.n, let e = key.e,
                  let modulus = OAuthEncoding.decodeBase64URL(n), let exponent = OAuthEncoding.decodeBase64URL(e),
                  let secKey = rsaPublicKey(modulus: modulus, exponent: exponent)
            else { continue }
            result[kid] = secKey
        }
        return result
    }

    /// RSA の公開鍵（PKCS#1 の RSAPublicKey）を作る。
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        let der = DER.sequence([DER.unsignedInteger(modulus), DER.unsignedInteger(exponent)])
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.drop(while: { $0 == 0 }).count * 8,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
        error?.release()
        return key
    }
}

/// RSA の公開鍵を表すのに必要なだけの DER（ASN.1）の組み立て。
enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    /// 符号なしの整数。先頭の余分な 0 を除き、最上位ビットが立っていれば 0x00 を前に付ける（負の数と読まれないように）
    static func unsignedInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
        return Data([0x02]) + length(value.count) + value
    }

    static func sequence(_ elements: [Data]) -> Data {
        let content = elements.reduce(Data(), +)
        return Data([0x30]) + length(content.count) + content
    }
}
