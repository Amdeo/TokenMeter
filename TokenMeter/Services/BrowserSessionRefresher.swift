import Foundation

/// 网页登录态的续期流程。APIKEY.FUN 与 CCBus 的前端续期接口同构：
/// `POST {api}/auth/refresh`，body `{"refresh_token": ...}`，
/// 响应 `{code, data: {access_token, refresh_token, expires_in}}`（code 为 0 表示成功）。
///
/// 这里只抛语义错误，由各供应商映射成自己的错误类型——Provider 的 `isInvalid`
/// 判定依赖具体错误类型，所以不能把供应商错误类型也搬进来。
enum BrowserSessionRefresher {
    /// 续期失败的语义分类。
    enum Failure: Error, Equatable {
        /// refresh_token 被拒绝（400/401/403）：登录态确实失效，需要重新登录。
        case invalidCredentials
        /// 网络/服务端/响应不可解析：暂时失败，不应让调用方误判为需要重新登录。
        case requestFailed(String)
    }

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

    /// 用 refresh_token 换取新的登录态。
    /// - Note: 响应不是 HTTP 响应时由 `HTTPTransport.live` 抛 `URLError(.badServerResponse)`，
    ///   调用方按「暂时失败」处理（与原先 `.refreshFailed("无效响应")` 的归属一致）。
    static func refresh(
        _ credential: KimiBrowserCredential,
        apiBase: URL,
        transport: HTTPTransport = .live
    ) async throws -> KimiBrowserCredential {
        var request = URLRequest(url: apiBase.appendingPathComponent("/auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["refresh_token": credential.refreshToken])

        let (data, http) = try await transport.send(request)
        guard (200..<300).contains(http.statusCode) else {
            // 400/401/403 表示 refresh_token 被拒绝（登录态真失效）；
            // 其余状态码（5xx/429）是服务问题，不应让调用方误判为需要重新登录。
            if [400, 401, 403].contains(http.statusCode) {
                throw Failure.invalidCredentials
            }
            throw Failure.requestFailed("HTTP \(http.statusCode)")
        }

        guard let payload = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              payload.code == 0,
              let payloadData = payload.data,
              let accessToken = payloadData.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty,
              let refreshToken = payloadData.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            throw Failure.invalidCredentials
        }

        let expiresAt: Date
        if let expiresIn = payloadData.expiresIn, expiresIn > 0 {
            expiresAt = Date.now.addingTimeInterval(expiresIn)
        } else if let parsed = JWT.expiration(of: accessToken) {
            // 前端响应缺少 expires_in 时，退回 access_token 自带的 exp。
            expiresAt = parsed
        } else {
            throw Failure.invalidCredentials
        }

        return KimiBrowserCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: "Bearer"
        )
    }
}
