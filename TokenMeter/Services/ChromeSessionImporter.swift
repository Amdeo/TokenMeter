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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiBrowserCredentialError.refreshFailed("无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KimiBrowserCredentialError.refreshFailed("HTTP \(http.statusCode)")
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw KimiBrowserCredentialError.refreshFailed("响应不可读")
        }
        // 刷新响应字段为 camelCase（accessToken/refreshToken），与提取解析复用同一入口。
        return try KimiBrowserCredentialExtractor.credential(from: raw)
    }

    /// 通用有限重试循环，保留协作式取消；供需要轮询/重试的调用方使用。
    static func retrying<Value: Sendable>(
        maximumAttempts: Int,
        retryDelay: Duration,
        attempt: (Int) async throws -> Value?
    ) async throws -> Value? {
        for index in 0..<maximumAttempts {
            try Task.checkCancellation()
            if let value = try await attempt(index) {
                return value
            }
            try Task.checkCancellation()
            guard index + 1 < maximumAttempts else { break }
            try await Task.sleep(for: retryDelay)
        }
        return nil
    }
}
