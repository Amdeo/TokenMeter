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

/// token 型网页登录态的站点差异：localStorage 键名、登录窗口与提取规则。
/// 内嵌登录窗口与凭证提取共用这一处定义，不再每个供应商一份实现。
struct BrowserTokenSite: Sendable {
    /// 错误文案里的供应商名（如 "CCBus"、"Siyu API"）。
    let displayName: String
    /// 内嵌登录窗口标题。
    let loginWindowTitle: String
    /// localStorage 中 access token 的键名。
    let accessTokenKey: String
    /// 是否要求 refresh token 本身也是带 exp 的 JWT（Kimi）。
    var validatesRefreshTokenExpiry = false
    /// 登录页所在域（含子域）。
    let sessionDomains: [String]
    let loginPageURL: URL

    /// 读取 localStorage 登录态的 JS，返回形如
    /// {"accessToken": ..., "refreshToken": ...} 的 JSON 字符串。
    var extractionJavaScript: String {
        #"(() => JSON.stringify({accessToken: localStorage.getItem("\#(accessTokenKey)"), refreshToken: localStorage.getItem("refresh_token")}))()"#
    }

    /// 校验 JWT 并构造凭证：格式错、缺字段、已过期分别抛对应错误。
    func credential(from rawValue: String) throws -> KimiBrowserCredential {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TokenPayload.self, from: data) else {
            throw BrowserLoginError.invalidCredentials(provider: displayName)
        }
        guard let accessToken = payload.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              let refreshToken = payload.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw BrowserLoginError.credentialsMissing(provider: displayName)
        }
        guard let expiresAt = JWT.expiration(of: accessToken) else {
            throw BrowserLoginError.invalidCredentials(provider: displayName)
        }
        if validatesRefreshTokenExpiry, JWT.expiration(of: refreshToken) == nil {
            throw BrowserLoginError.invalidCredentials(provider: displayName)
        }
        guard expiresAt > .now else {
            throw BrowserLoginError.expired(provider: displayName)
        }
        return KimiBrowserCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: "Bearer"
        )
    }

    private struct TokenPayload: Decodable {
        let accessToken: String?
        let refreshToken: String?
    }
}

extension BrowserTokenSite {
    /// Kimi：登录页即用量页，localStorage 键为 access_token，refresh token 也须是带 exp 的 JWT。
    static let kimi = BrowserTokenSite(
        displayName: "Kimi",
        loginWindowTitle: "登录 Kimi 账号",
        accessTokenKey: "access_token",
        validatesRefreshTokenExpiry: true,
        sessionDomains: ["kimi.com"],
        loginPageURL: URL(string: ChromeSessionImporter.quotaURL)!
    )

    /// CCBus（AI 巴士）。
    static let ccbus = BrowserTokenSite(
        displayName: "CCBus",
        loginWindowTitle: "登录 CCBus（AI 巴士）账号",
        accessTokenKey: "auth_token",
        sessionDomains: ["ccbus.top"],
        loginPageURL: URL(string: "https://ccbus.top/login")!
    )

    /// APIKEY.FUN。
    static let apiKeyFun = BrowserTokenSite(
        displayName: "APIKEY.FUN",
        loginWindowTitle: "登录 APIKEY.FUN 账号",
        accessTokenKey: "auth_token",
        sessionDomains: ["apikey.fun"],
        loginPageURL: URL(string: "https://apikey.fun/login")!
    )

    /// Siyu API。
    static let siyu = BrowserTokenSite(
        displayName: "Siyu API",
        loginWindowTitle: "登录 Siyu API 账号",
        accessTokenKey: "auth_token",
        sessionDomains: ["siyu.site"],
        loginPageURL: URL(string: "https://siyu.site/login")!
    )
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

extension BrowserRelayRefresher {
    static let ccbus = BrowserRelayRefresher(
        site: .ccbus, apiBase: URL(string: "https://ccbus.top/api/v1")!
    )
    static let apiKeyFun = BrowserRelayRefresher(
        site: .apiKeyFun, apiBase: URL(string: "https://apikey.fun/api/v1")!
    )
    static let siyu = BrowserRelayRefresher(
        site: .siyu, apiBase: URL(string: "https://siyu.site/api/v1")!
    )
}
