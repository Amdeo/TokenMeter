import Foundation

/// Siyu API 网页登录态的续期服务。
/// 登录态获取由 `EmbeddedWebLoginController`（内嵌 WKWebView）负责，
/// 本类型只提供供应商常量与「语义错误 → 供应商错误」的映射。
/// 参考前端实现：`POST {api}/auth/refresh`，body `{"refresh_token": ...}`。
struct SiyuSessionRefresher: Sendable {
    static let apiBase = URL(string: "https://siyu.site/api/v1")!
    static let loginPageURL = URL(string: "https://siyu.site/login")!

    /// 续期入口（`BrowserSessionFlow` 的 refresh 闭包直接引用本方法）。
    static func refresh(_ credential: KimiBrowserCredential) async throws -> KimiBrowserCredential {
        try await refresh(credential, transport: .live)
    }

    /// 同一流程，额外暴露传输层以便测试覆盖错误映射。
    static func refresh(
        _ credential: KimiBrowserCredential,
        transport: HTTPTransport
    ) async throws -> KimiBrowserCredential {
        do {
            return try await BrowserSessionRefresher.refresh(
                credential, apiBase: apiBase, transport: transport
            )
        } catch BrowserSessionRefresher.Failure.invalidCredentials {
            throw SiyuBrowserCredentialError.expired
        } catch BrowserSessionRefresher.Failure.requestFailed(let message) {
            throw SiyuBrowserCredentialError.refreshFailed(message)
        }
    }
}
