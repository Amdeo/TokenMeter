import Foundation

// MARK: - 定义

/// 中转站供应商（CCBus / APIKEY.FUN）：同一套前端接口（`/auth/refresh`、`/auth/me`）
/// 与同一张余额卡片，差异只有站点常量与展示元数据。
@MainActor
struct RelayBalanceProviderDefinition: ProviderDefinition {
    /// 站点常量与续期入口。
    let site: BrowserRelayRefresher
    let id: ProviderID
    /// 选择页/卡片展示名（可与错误文案里的短名不同，如「CCBus（AI 巴士）」）。
    let displayName: String
    let iconResourceName: String
    let fallbackSystemImage: String
    let tintRGB: UInt32
    let homepageURL: URL
    let authMethod: AuthMethodDefinition
    /// Demo 快照展示的余额。
    let demoBalance: Double

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: displayName,
            iconResourceName: iconResourceName,
            fallbackSystemImage: fallbackSystemImage,
            tintRGB: tintRGB,
            capabilityDescription: "支持账户余额，可通过网页登录态获取。",
            authPageURL: site.site.loginPageURL,
            homepageURL: homepageURL,
            authenticationSummary: "网页登录态 · 支持账户余额"
        )
    }

    var authMethods: [AuthMethodDefinition] { [authMethod] }

    let cardRenderer: any ProviderCardRenderer = BalanceCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        RelayBalanceUsageProvider(subscription: subscription, site: site)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额",
                used: 0,
                limit: demoBalance,
                resetAt: nil,
                unit: .currency(code: "USD", scale: 1),
                kind: .balance
            )
        ])
    }
}

extension RelayBalanceProviderDefinition {
    static let ccbus = RelayBalanceProviderDefinition(
        site: .ccbus,
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
            detail: "登录 CCBus 账号（内置）"
        ),
        demoBalance: 23.22
    )

    static let apiKeyFun = RelayBalanceProviderDefinition(
        site: .apiKeyFun,
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
            detail: "登录 APIKEY.FUN 账号（内置）"
        ),
        demoBalance: 18.14
    )
}

// MARK: - 用量提供者

struct RelayBalanceUsageProvider: UsageProvider {
    let subscription: Subscription
    let site: BrowserRelayRefresher
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let stored = credentials.browserCredential(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let configuration = BrowserSessionFlow.Configuration(
            providerID: subscription.providerID,
            subscriptionID: subscription.id,
            credentials: credentials,
            providerName: site.site.displayName,
            isUsable: { $0.expiresAt.timeIntervalSinceNow > 300 },
            refresh: { try await site.refresh($0) }
        )
        return try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: stored,
            fetch: { try await fetchBalance(credential: $0) }
        )
    }

    private func fetchBalance(credential: KimiBrowserCredential) async throws -> UsageSnapshot {
        let response: MeResponse = try await APIClient.get(
            site.apiBase.appendingPathComponent("/auth/me"),
            providerID: subscription.providerID,
            authorization: "\(credential.tokenType) \(credential.accessToken)"
        )
        guard response.code == 0, let data = response.data else {
            throw UsageProviderError.invalidResponse(
                subscription.providerID, "\(site.site.displayName) 返回中缺少余额字段"
            )
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额",
                used: 0,
                limit: data.balance,
                resetAt: nil,
                unit: .currency(code: "USD", scale: 1),
                kind: .balance
            )
        ])
    }
}

// MARK: - 响应类型

private struct MeResponse: Decodable {
    struct Data: Decodable {
        let balance: Double
    }

    let code: Int
    let data: Data?
}
