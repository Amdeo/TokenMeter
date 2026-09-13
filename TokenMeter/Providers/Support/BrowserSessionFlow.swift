import Foundation

/// Kimi / CCBus / APIKEY.FUN 共用的「浏览器令牌会话」通用刷新流程。
///
/// 三家供应商的登录态结构相同（accessToken + refreshToken + expiresAt，
/// 即 `BrowserTokenCredential`），刷新接口同构（用 refresh_token 换新），
/// 业务请求遇到 401/403 时兑底再刷新一次。把这份同构逻辑收敛到这里，
/// 避免三个 Provider 各维护一份几乎相同的 fetchUsage 骨架。
///
/// 错误语义统一：只有 refresh_token 被拒绝（expired / invalidCredentials）
/// 才判定登录态失效（认证失效状态）；网络错误与 5xx 属于暂时失败
/// （请求失败状态），不再误报「请重新登录」。
enum BrowserSessionFlow {
    /// 单个供应商的浏览器会话流程配置。
    struct Configuration {
        let providerID: ProviderID
        let subscriptionID: UUID
        let credentials: CredentialStore
        /// 展示给用户的供应商名，用于「XX 网页登录态已过期」文案。
        let providerName: String
        /// 现有凭证是否仍可直接使用（通常按 expiresAt 判断）。
        let isUsable: (BrowserTokenCredential) -> Bool
        /// 以 refresh_token 换新登录态。
        let refresh: (BrowserTokenCredential) async throws -> BrowserTokenCredential

        /// 凭证失效时呈现的认证失效消息。
        var invalidMessage: String {
            "\(providerName) 网页登录态已过期，请在订阅设置中重新登录"
        }

        /// 只有登录态本身失效（而非网络/服务端问题）才判定为需要重新登录。
        func isInvalid(_ error: Error) -> Bool {
            (error as? BrowserLoginError)?.indicatesInvalidCredential ?? false
        }
    }

    /// 读取并（必要时）刷新登录态，返回可用凭证。
    /// 刷新成功后立即回写凭证文件（写入前检查任务取消状态）。
    /// - Parameter forceRefresh: 置 true 时无条件刷新（401/403 兑底重试场景）。
    static func refreshedCredential(
        _ configuration: Configuration,
        stored: BrowserTokenCredential,
        forceRefresh: Bool = false
    ) async throws -> BrowserTokenCredential {
        if !forceRefresh, configuration.isUsable(stored) { return stored }
        do {
            let refreshed = try await configuration.refresh(stored)
            // 写入前检查取消状态：订阅可能已被删除或切换认证方式。
            try Task.checkCancellation()
            try configuration.credentials.save(browserCredential: refreshed, for: configuration.subscriptionID)
            return refreshed
        } catch is CancellationError {
            throw CancellationError()
        } catch where configuration.isInvalid(error) {
            throw UsageProviderError.authenticationRequired(
                configuration.providerID, configuration.invalidMessage
            )
        } catch {
            throw UsageProviderError.requestFailed(
                configuration.providerID, "登录态续期失败，请稍后重试"
            )
        }
    }

    /// 通用获取流程：现有凭证不可用则先刷新；业务请求 401/403 且
    /// 本周期尚未刷新过时，再兑底刷新一次重试；否则按凭证失效处理。
    static func fetchWithRetry<Result>(
        _ configuration: Configuration,
        stored: BrowserTokenCredential,
        fetch: (BrowserTokenCredential) async throws -> Result
    ) async throws -> Result {
        var credential = stored
        var didRefresh = false
        if !configuration.isUsable(stored) {
            credential = try await refreshedCredential(configuration, stored: stored)
            didRefresh = true
        }
        do {
            return try await fetch(credential)
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            guard !didRefresh else {
                throw UsageProviderError.authenticationRequired(
                    configuration.providerID, configuration.invalidMessage
                )
            }
            let retried = try await refreshedCredential(
                configuration, stored: credential, forceRefresh: true
            )
            return try await fetch(retried)
        }
    }
}