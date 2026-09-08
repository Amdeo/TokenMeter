import Foundation

enum KimiBrowserCredentialError: LocalizedError, Sendable {
    case credentialsMissing
    case invalidCredentials
    case expired
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "未找到 Kimi 登录态，请先登录后重试。"
        case .invalidCredentials:
            return "Kimi 登录态格式无效，请重新登录后重试。"
        case .expired:
            return "Kimi 登录态已过期，请重新登录后重试。"
        case .refreshFailed(let message):
            return "刷新 Kimi 登录态失败：\(message)。请重新登录 Kimi 账号。"
        }
    }

    /// 该错误是否表示登录态本身失效（而非网络/服务端暂时问题）。
    var indicatesInvalidCredential: Bool {
        switch self {
        case .expired, .invalidCredentials: true
        case .credentialsMissing, .refreshFailed: false
        }
    }
}

/// Kimi 网页登录态的续期服务与共享页面地址。
/// 登录态获取由 `EmbeddedKimiLoginController`（内嵌 WKWebView）负责，
/// 本类型仅承担 access_token 到期后的 RefreshToken RPC 续期。
struct ChromeSessionImporter: Sendable {
    static let quotaURL = "https://www.kimi.com/settings/subscription?tab=quota"

    /// Kimi 网页版刷新端点的服务名（auth.kimi.com 的 Connect RPC）。
    private static let refreshTokenEndpoint = URL(string: "https://auth.kimi.com/api/account.gateway.v1.AuthService/RefreshToken")!

    /// 用 refresh_token 换取新的网页登录态。Kimi 网页的 access_token 有效期很短
    /// （约一小时），refresh_token 长期有效，刷新成功后须回写凭证文件。
    static func refresh(_ credential: KimiBrowserCredential) async throws -> KimiBrowserCredential {
        var request = URLRequest(url: refreshTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["refresh_token": credential.refreshToken])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw KimiBrowserCredentialError.refreshFailed("无效响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                // 401/403/400 表示 refresh_token 被拒绝（登录态真失效）；
                // 其余状态码（5xx/429）是服务问题，不应让调用方误判为需要重新登录。
                if [400, 401, 403].contains(http.statusCode) {
                    throw KimiBrowserCredentialError.expired
                }
                throw KimiBrowserCredentialError.refreshFailed("HTTP \(http.statusCode)")
            }
            guard let raw = String(data: data, encoding: .utf8) else {
                throw KimiBrowserCredentialError.refreshFailed("响应不可读")
            }
            // 刷新响应字段为 camelCase（accessToken/refreshToken），与提取解析复用同一入口。
            return try KimiBrowserCredentialExtractor.credential(from: raw)
        } catch let error as KimiBrowserCredentialError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KimiBrowserCredentialError.refreshFailed(error.localizedDescription)
        }
    }

}
