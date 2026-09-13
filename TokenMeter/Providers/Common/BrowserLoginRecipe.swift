import Foundation

// MARK: - 登录配方

/// 网页登录态的声明式配方：供应商在自己的认证方式定义里提供，共享代码据此构造
/// 内嵌登录窗口与凭证提取。这是共享代码里不再出现供应商名字的前提。
///
/// `displayName` 承担错误文案里的短名（如 "CCBus"），可以与界面展示名不同。
struct BrowserLoginRecipe: Sendable, Equatable {
    let displayName: String
    /// 内嵌登录窗口标题。
    let windowTitle: String
    /// 登录页所在域（含子域）：既用于判定何时可以尝试提取，也用于切换账号时清站点数据。
    let sessionDomains: [String]
    let loginPageURL: URL
    let extraction: Extraction

    /// 登录态的存放方式。
    enum Extraction: Sendable, Equatable {
        /// localStorage 里存放 access / refresh token，凭证是 JWT。
        case localStorageTokens(
            accessTokenKey: String,
            refreshTokenKey: String,
            validatesRefreshTokenExpiry: Bool
        )
        /// HttpOnly session cookie + localStorage 里的用户 ID（new-api 系）。
        case sessionCookie(name: String, userIDLocalStorageKey: String)
    }
}

// MARK: - token 型提取

extension BrowserLoginRecipe {
    /// 读取 localStorage 登录态的 JS，返回形如
    /// `{"accessToken": ..., "refreshToken": ...}` 的 JSON 字符串。
    /// 仅 `localStorageTokens` 型有意义。
    var extractionJavaScript: String {
        guard case .localStorageTokens(let accessTokenKey, let refreshTokenKey, _) = extraction else {
            return ""
        }
        return #"(() => JSON.stringify({accessToken: localStorage.getItem("\#(accessTokenKey)"), refreshToken: localStorage.getItem("\#(refreshTokenKey)")}))()"#
    }

    /// 校验 JWT 并构造凭证：格式错、缺字段、已过期分别抛对应错误。
    /// 仅 `localStorageTokens` 型有意义；其余类型的站点走 cookie 提取。
    func tokenCredential(from rawValue: String) throws -> BrowserTokenCredential {
        guard case .localStorageTokens(_, _, let validatesRefreshTokenExpiry) = extraction else {
            throw BrowserLoginError.invalidCredentials(provider: displayName)
        }
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
        // 只有要求 refresh token 也是带 exp 的 JWT 的站点才做这项校验（目前仅 Kimi）。
        if validatesRefreshTokenExpiry, JWT.expiration(of: refreshToken) == nil {
            throw BrowserLoginError.invalidCredentials(provider: displayName)
        }
        guard expiresAt > .now else {
            throw BrowserLoginError.expired(provider: displayName)
        }
        return BrowserTokenCredential(
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
