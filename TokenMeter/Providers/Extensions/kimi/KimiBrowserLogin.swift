import Foundation

// MARK: - 登录站点

extension BrowserTokenSite {
    /// Kimi：登录页即用量页，localStorage 键为 access_token，
    /// 且 refresh token 也必须是带 exp 的 JWT。
    static let kimi = BrowserTokenSite(
        displayName: "Kimi",
        loginWindowTitle: "登录 Kimi 账号",
        accessTokenKey: "access_token",
        validatesRefreshTokenExpiry: true,
        sessionDomains: ["kimi.com"],
        loginPageURL: URL(string: ChromeSessionImporter.quotaURL)!
    )
}

