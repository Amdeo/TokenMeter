import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let ccbus = ProviderID(rawValue: "ccbus")
}

extension AuthMethodID {
    static let ccbusBrowserSession = AuthMethodID(rawValue: "ccbus-browser-session")
}

// MARK: - 登录站点

extension BrowserTokenSite {
    /// CCBus（AI 巴士）：localStorage 键为 auth_token，续期走 `POST {apiBase}/auth/refresh`。
    static let ccbus = BrowserTokenSite(
        displayName: "CCBus",
        loginWindowTitle: "登录 CCBus（AI 巴士）账号",
        accessTokenKey: "auth_token",
        sessionDomains: ["ccbus.top"],
        loginPageURL: URL(string: "https://ccbus.top/login")!
    )
}


extension BrowserRelayRefresher {
    static let ccbus = BrowserRelayRefresher(
        tokenSite: .ccbus, apiBase: URL(string: "https://ccbus.top/api/v1")!
    )
}

// MARK: - 定义

/// 余额型中转站：接口与卡片由 `RelayBalanceProviderDefinition` 提供，这里只有站点差异。
extension RelayBalanceProviderDefinition {
    static let ccbus = RelayBalanceProviderDefinition(
        refresher: .ccbus,
        id: .ccbus,
        displayName: "CCBus（AI 巴士）",
        iconResourceName: "icon-ccbus",
        fallbackSystemImage: "bus.fill",
        tintRGB: 0x2DD4BF,
        homepageURL: URL(string: "https://ccbus.top")!,
        authMethod: AuthMethodDefinition(
            id: .ccbusBrowserSession,
            flowID: .browserSession,
            title: "网页登录态",
            systemImage: "globe",
            tintRGB: 0x2DD4BF,
            detail: "登录 CCBus 账号（内置）",
            loginRecipe: BrowserTokenSite.ccbus.loginRecipe
        )
    )
}
