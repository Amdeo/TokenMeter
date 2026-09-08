import Foundation

/// CCBus（AI 巴士）网页登录态的续期服务。
/// 登录态获取由 `EmbeddedCCBusLoginController`（内嵌 WKWebView）负责，
/// 本类型仅承担 access_token 到期后的 refresh_token 续期。
/// 参考前端实现：`POST {api}/auth/refresh`，body `{"refresh_token": ...}`。
struct CCBusSessionRefresher: Sendable {
    static let apiBase = URL(string: "https://ccbus.top/api/v1")!
    static let loginPageURL = URL(string: "https://ccbus.top/login")!

    private static let refreshEndpoint = apiBase.appendingPathComponent("/auth/refresh")

    struct RefreshResponse: Decodable {
        struct Data: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let expiresIn: Double?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }

        let code: Int
        let data: Data?
    }

    /// 用 refresh_token 换取新的登录态；成功后回写凭证文件。
    static func refresh(_ credential: KimiBrowserCredential) async throws -> KimiBrowserCredential {
        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["refresh_token": credential.refreshToken])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CCBusBrowserCredentialError.refreshFailed("无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 401/403/400 表示 refresh_token 被拒绝（登录态真失效）；
            // 其余状态码（5xx/429）是服务问题，不应让调用方误判为需要重新登录。
            if [400, 401, 403].contains(http.statusCode) {
                throw CCBusBrowserCredentialError.expired
            }
            throw CCBusBrowserCredentialError.refreshFailed("HTTP \(http.statusCode)")
        }
        guard let payload = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              payload.code == 0,
              let data = payload.data,
              let accessToken = data.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty,
              let refreshToken = data.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            throw CCBusBrowserCredentialError.invalidCredentials
        }
        let expiresAt: Date
        if let expiresIn = data.expiresIn, expiresIn > 0 {
            expiresAt = Date.now.addingTimeInterval(expiresIn)
        } else if let parsed = Self.expiration(of: accessToken) {
            expiresAt = parsed
        } else {
            throw CCBusBrowserCredentialError.invalidCredentials
        }
        return KimiBrowserCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, tokenType: "Bearer")
    }

    /// 从 JWT 载荷解析 exp 过期时间（前端 refresh 响应无 expires_in 时兜底）。
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
}
