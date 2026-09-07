import Foundation

/// Kimi 网页登录态的共享提取入口：从 Kimi 网页 localStorage 读出的
/// access_token/refresh_token JSON 出发，校验并构造凭证。
/// 内嵌 WKWebView 登录与 token 续期共用同一出口。
enum KimiBrowserCredentialExtractor {
    /// 读取 Kimi 网页 localStorage 中登录态的 JS，返回形如
    /// {"accessToken": ..., "refreshToken": ...} 的 JSON 字符串。
    static let extractionJavaScript = #"(() => JSON.stringify({accessToken: localStorage.getItem("access_token"), refreshToken: localStorage.getItem("refresh_token")}))()"#

    static func credential(from rawValue: String) throws -> KimiBrowserCredential {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TokenPayload.self, from: data) else {
            throw KimiBrowserCredentialError.invalidCredentials
        }
        guard let accessToken = payload.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              let refreshToken = payload.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw KimiBrowserCredentialError.credentialsMissing
        }
        guard let expiresAt = Self.expiration(of: accessToken) else {
            throw KimiBrowserCredentialError.invalidCredentials
        }
        guard Self.expiration(of: refreshToken) != nil else {
            throw KimiBrowserCredentialError.invalidCredentials
        }
        guard expiresAt > .now else {
            throw KimiBrowserCredentialError.expired
        }
        return KimiBrowserCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, tokenType: "Bearer")
    }

    private static func expiration(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["exp"] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: value.doubleValue)
    }

    private struct TokenPayload: Decodable {
        let accessToken: String?
        let refreshToken: String?
    }
}
