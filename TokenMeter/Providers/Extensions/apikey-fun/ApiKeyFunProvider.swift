import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let apikeyFun = ProviderID(rawValue: "apikey-fun")
}

extension AuthMethodID {
    static let apikeyFunBrowserSession = AuthMethodID(rawValue: "apikey-fun-browser-session")
}

// MARK: - 登录站点

extension BrowserTokenSite {
    /// APIKEY.FUN：localStorage 键为 auth_token，续期走 `POST {apiBase}/auth/refresh`。
    static let apiKeyFun = BrowserTokenSite(
        displayName: "APIKEY.FUN",
        loginWindowTitle: "登录 APIKEY.FUN 账号",
        accessTokenKey: "auth_token",
        sessionDomains: ["apikey.fun"],
        loginPageURL: URL(string: "https://apikey.fun/login")!
    )
}


extension BrowserRelayRefresher {
    static let apiKeyFun = BrowserRelayRefresher(
        tokenSite: .apiKeyFun, apiBase: URL(string: "https://apikey.fun/api/v1")!
    )
}

// MARK: - 定义

/// 余额型中转站：接口与卡片由 `RelayBalanceProviderDefinition` 提供，这里只有站点差异。
extension RelayBalanceProviderDefinition {
    static let apiKeyFun = RelayBalanceProviderDefinition(
        refresher: .apiKeyFun,
        id: .apikeyFun,
        displayName: "APIKEY.FUN",
        iconResourceName: "icon-apikeyfun",
        fallbackSystemImage: "key.fill",
        tintRGB: 0x6E6CF0,
        homepageURL: URL(string: "https://apikey.fun")!,
        authMethod: AuthMethodDefinition(
            id: .apikeyFunBrowserSession,
            flowID: .browserSession,
            title: "网页登录态",
            systemImage: "globe",
            tintRGB: 0x6E6CF0,
            detail: "登录 APIKEY.FUN 账号（内置）",
            loginRecipe: BrowserTokenSite.apiKeyFun.loginRecipe
        )
    )
}
