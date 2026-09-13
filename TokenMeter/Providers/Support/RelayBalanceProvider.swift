import Foundation

// MARK: - 定义

/// 中转站供应商的通用实现：同一套前端接口（`/auth/refresh`、`/auth/me`）
/// 与同一张余额卡片，差异只有站点常量与展示元数据。
/// 具体站点在各自目录里用一条 `static let` 实例化它，见 `Providers/Extensions/<id>/`。
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

    @MainActor var cardRenderer: any ProviderCardRenderer { BalanceCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        RelayBalanceUsageProvider(subscription: subscription, site: site)
    }

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
            authorization: "\(credential.tokenType) \(credential.accessToken)",
            statusPolicy: .raw
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
