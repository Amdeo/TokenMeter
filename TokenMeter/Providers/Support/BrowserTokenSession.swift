import Foundation

// MARK: - 登录态错误

/// token 型网页登录态的统一错误。
/// 原先 Kimi / CCBus / APIKEY.FUN / Siyu 各有一个逐行相同的错误枚举，
/// 差异只有文案里的供应商名；`provider` 参数承担这份差异。
enum BrowserLoginError: LocalizedError, Sendable, Equatable {
    case credentialsMissing(provider: String)
    case invalidCredentials(provider: String)
    case expired(provider: String)
    /// 续期请求失败（网络/服务端问题），不等于凭证失效。
    case refreshFailed(provider: String, message: String)

    var providerName: String {
        switch self {
        case .credentialsMissing(let provider),
             .invalidCredentials(let provider),
             .expired(let provider),
             .refreshFailed(let provider, _):
            provider
        }
    }

    /// 该错误是否表示登录态本身失效（而非网络/服务端暂时问题）。
    var indicatesInvalidCredential: Bool {
        switch self {
        case .expired, .invalidCredentials: true
        case .credentialsMissing, .refreshFailed: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .credentialsMissing(let provider):
            "未找到 \(provider) 登录态，请先登录后重试。"
        case .invalidCredentials(let provider):
            "\(provider) 登录态格式无效，请重新登录后重试。"
        case .expired(let provider):
            "\(provider) 登录态已过期，请重新登录后重试。"
        case .refreshFailed(let provider, let message):
            "刷新 \(provider) 登录态失败：\(message)。请稍后重试。"
        }
    }
}

// MARK: - 站点定义

/// token 型网页登录态的站点差异：localStorage 键名与续期用的短名。
///
/// 站点常量（域名、登录页、键名、续期前缀）与供应商放在一起，
/// 见 `Providers/Extensions/<id>/`。
/// 登录窗口与凭证提取规则统一由 `BrowserLoginRecipe` 承担，本类型只提供
/// 「站点身份（错误文案短名）+ 续期所需信息」这一运行时视图，提取逻辑因此
/// 只有一份实现。
struct BrowserTokenSite: Sendable {
    /// 错误文案里的供应商名（如 "CCBus"、"Siyu API"）。
    let displayName: String
    /// 内嵌登录窗口标题。
    let loginWindowTitle: String
    /// localStorage 中 access token 的键名。
    let accessTokenKey: String
    /// localStorage 中 refresh token 的键名。
    var refreshTokenKey = "refresh_token"
    /// 是否要求 refresh token 本身也是带 exp 的 JWT（Kimi）。
    var validatesRefreshTokenExpiry = false
    /// 登录页所在域（含子域）。
    let sessionDomains: [String]
    let loginPageURL: URL

    /// 登录相关的唯一声明处：登录窗口配置与凭证提取都由它派生。
    var loginRecipe: BrowserLoginRecipe {
        BrowserLoginRecipe(
            displayName: displayName,
            windowTitle: loginWindowTitle,
            sessionDomains: sessionDomains,
            loginPageURL: loginPageURL,
            extraction: .localStorageTokens(
                accessTokenKey: accessTokenKey,
                refreshTokenKey: refreshTokenKey,
                validatesRefreshTokenExpiry: validatesRefreshTokenExpiry
            )
        )
    }

    var extractionJavaScript: String { loginRecipe.extractionJavaScript }

    func credential(from rawValue: String) throws -> KimiBrowserCredential {
        try loginRecipe.tokenCredential(from: rawValue)
    }
}

// MARK: - 中转站续期

/// 中转站续期端点：与 `BrowserTokenSite` 组合，表示
/// 「`POST {apiBase}/auth/refresh` 可续期」的站点。
/// CCBus / APIKEY.FUN / Siyu 的前端续期接口同构，共用 `BrowserSessionRefresher`。
struct BrowserRelayRefresher: Sendable {
    let site: BrowserTokenSite
    let apiBase: URL

    /// 续期入口（`BrowserSessionFlow` 的 refresh 闭包直接引用）。
    func refresh(_ credential: KimiBrowserCredential) async throws -> KimiBrowserCredential {
        try await refresh(credential, transport: .live)
    }

    /// 同一流程，额外暴露传输层以便测试覆盖错误映射。
    func refresh(
        _ credential: KimiBrowserCredential,
        transport: HTTPTransport
    ) async throws -> KimiBrowserCredential {
        do {
            return try await BrowserSessionRefresher.refresh(
                credential, apiBase: apiBase, transport: transport
            )
        } catch BrowserSessionRefresher.Failure.invalidCredentials {
            throw BrowserLoginError.expired(provider: site.displayName)
        } catch BrowserSessionRefresher.Failure.requestFailed(let message) {
            throw BrowserLoginError.refreshFailed(provider: site.displayName, message: message)
        }
    }
}
