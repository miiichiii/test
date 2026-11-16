import CryptoKit
import Foundation
import Security

/// OAuth のための小さな道具（DESIGN.md §4.11）。
enum OAuthEncoding {
    /// RFC 3986 の予約されていない文字（英数字と `-._~`）だけを残し、ほかはすべて `%XX` にする。
    /// `URLComponents` は `+` をエンコードしないので、form の本文やクエリでトークンが壊れないよう自前で行う。
    static func percentEncode(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// `key=value&key=value`（順序を保つ）
    static func formBody(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    /// base64url（パディングなし）
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url（パディングあり・なしの両方）を読む。
    static func decodeBase64URL(_ text: some StringProtocol) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    /// PKCE の code_challenge（検証子の SHA-256 を base64url にしたもの）
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// 乱数のバイト列を作る。テストでは決まった値を返すものに差し替える。
public typealias RandomBytes = @Sendable (Int) -> Data

/// OS の暗号学的な乱数（`SecRandomCopyBytes`）。
public let systemRandomBytes: RandomBytes = { count in
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    // 失敗はまず起きないが、起きたら予測できる値で続けないよう、システムの乱数生成器で埋める。
    if status != errSecSuccess {
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
    }
    return Data(bytes)
}
