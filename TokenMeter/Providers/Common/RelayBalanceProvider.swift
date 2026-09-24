import Foundation

// MARK: - 定义

/// 中转站供应商的通用实现：同一套前端接口（`/auth/refresh`、`/auth/me`）
/// 与同一张余额卡片，差异只有站点常量与展示元数据。
/// 具体站点在各自目录里用一条 `static let` 实例化它，见 `Providers/Extensions/<id>/`。
struct RelayBalanceProviderDefinition: ProviderDefinition {
    /// 站点常量与续期入口。
    let refresher: BrowserRelayRefresher
    let id: ProviderID
    /// 选择页/卡片展示名（可与错误文案里的短名不同，如「CCBus（AI 巴士）」）。
    let displayName: String
    /// Bundle 内图标资源名；nil 时使用 `fallbackSystemImage`。
    let iconResourceName: String?
    let fallbackSystemImage: String
    /// 悬浮条与设置窗口侧边栏用的**单色**标记资源名；nil 时回落到 `fallbackSystemImage`。
    ///
    /// `var` 而不是 `let`：给它一个默认值，中转站里只有真拿到了像样标记的那几个才需要写。
    /// 中转站通常只有一张彩色应用图标，从里面剥出来的单色剪影只能是位图，
    /// 所以这个资源可以是 `.svg`，也可以是单色 `.png`（见 `RailMarkStore`）。
    var railMarkResource: String? = nil
    let tintRGB: UInt32
    let homepageURL: URL
    let authMethod: AuthMethodDefinition

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: displayName,
            iconResourceName: iconResourceName,
            fallbackSystemImage: fallbackSystemImage,
            tintRGB: tintRGB,
            railMarkResource: railMarkResource,
            capabilityDescription: "支持账户余额，可通过网页登录态获取。",
            authPageURL: refresher.tokenSite.loginPageURL,
            homepageURL: homepageURL,
            authenticationSummary: "网页登录态 · 支持账户余额"
        )
    }

    var authMethods: [AuthMethodDefinition] { [authMethod] }

    @MainActor var cardRenderer: any ProviderCardRenderer { BalanceCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        RelayBalanceUsageProvider(subscription: subscription, refresher: refresher)
    }

}

// MARK: - 用量提供者

struct RelayBalanceUsageProvider: UsageProvider {
    let subscription: Subscription
    let refresher: BrowserRelayRefresher
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let stored = credentials.browserCredential(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let configuration = BrowserSessionFlow.Configuration(
            providerID: subscription.providerID,
            subscriptionID: subscription.id,
            credentials: credentials,
            providerName: refresher.tokenSite.displayName,
            isUsable: { $0.expiresAt.timeIntervalSinceNow > 300 },
            refresh: { try await refresher.refresh($0) }
        )
        return try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: stored,
            fetch: { try await fetchBalance(credential: $0) }
        )
    }

    private func fetchBalance(credential: BrowserTokenCredential) async throws -> UsageSnapshot {
        let response: MeResponse = try await APIClient.get(
            refresher.apiBase.appendingPathComponent("/auth/me"),
            providerID: subscription.providerID,
            authorization: "\(credential.tokenType) \(credential.accessToken)",
            statusPolicy: .raw
        )
        guard response.code == 0, let data = response.data else {
            throw UsageProviderError.invalidResponse(
                subscription.providerID, "\(refresher.tokenSite.displayName) 返回中缺少余额字段"
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
