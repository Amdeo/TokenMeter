import Foundation

enum CCBusBrowserCredentialError: LocalizedError, Sendable {
    case credentialsMissing
    case invalidCredentials
    case expired

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "未找到 CCBus 登录态，请先登录后重试。"
        case .invalidCredentials:
            return "CCBus 登录态格式无效，请重新登录后重试。"
        case .expired:
            return "CCBus 登录态已过期，请重新登录后重试。"
        }
    }
}

/// CCBus（AI 巴士）网页登录态的提取入口：从 localStorage 读出
/// auth_token / refresh_token，校验 JWT 并构造凭证。
/// 内嵌 WKWebView 登录与 token 续期共用同一出口（与 Kimi 实现同构）。
enum CCBusBrowserCredentialExtractor {
    /// 读取 CCBus 网页 localStorage 中登录态的 JS，返回形如
    /// {"accessToken": ..., "refreshToken": ...} 的 JSON 字符串。
    static let extractionJavaScript = #"(() => JSON.stringify({accessToken: localStorage.getItem("auth_token"), refreshToken: localStorage.getItem("refresh_token")}))()"#

    static func credential(from rawValue: String) throws -> KimiBrowserCredential {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TokenPayload.self, from: data) else {
            throw CCBusBrowserCredentialError.invalidCredentials
        }
        guard let accessToken = payload.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              let refreshToken = payload.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw CCBusBrowserCredentialError.credentialsMissing
        }
        guard let expiresAt = Self.expiration(of: accessToken) else {
            throw CCBusBrowserCredentialError.invalidCredentials
        }
        guard expiresAt > .now else {
            throw CCBusBrowserCredentialError.expired
        }
        return KimiBrowserCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, tokenType: "Bearer")
    }

    /// 从 JWT 载荷解析 exp 过期时间。
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
