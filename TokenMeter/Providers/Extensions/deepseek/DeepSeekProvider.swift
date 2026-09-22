import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let deepSeek = ProviderID(rawValue: "deepseek")
}

// MARK: - 定义

struct DeepSeekProviderDefinition: ProviderDefinition {
    let id = ProviderID.deepSeek

    /// 旧 `Platform` 枚举里的名字。
    var legacyPlatformNames: [String] { ["DeepSeek"] }

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "DeepSeek",
            iconResourceName: "icon-deepseek",
            fallbackSystemImage: "bubble.left.and.bubble.right.fill",
            tintRGB: 0x0A84FF,
            iconInsetFraction: 0.08,
            railMarkResource: "deepseek",
            capabilityDescription: "支持余额接口，可使用 API Key。",
            authPageURL: URL(string: "https://platform.deepseek.com/api_keys"),
            homepageURL: URL(string: "https://platform.deepseek.com"),
            authenticationSummary: "API Key · 支持余额接口"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台")]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { BalanceCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        DeepSeekUsageProvider(subscription: subscription)
    }

}

// MARK: - 用量提供者

struct DeepSeekUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    /// 余额接口的状态码语义：401/403 是 Key 无效，402 余额不足，429 限流。
    private static let statusPolicy = HTTPStatusPolicy(
        unauthorizedMessage: "API Key 无效或无权访问余额接口",
        messages: [
            402: "账户余额不足",
            429: "请求过于频繁，请稍后重试",
        ]
    )

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let response: DeepSeekBalanceResponse = try await APIClient.get(
            URL(string: "https://api.deepseek.com/user/balance")!,
            providerID: subscription.providerID,
            authorization: "Bearer \(key)",
            statusPolicy: Self.statusPolicy
        )
        let balanceInfos = response.balanceInfos ?? []
        let validBalances = balanceInfos.compactMap { balance -> (currency: String, total: Double)? in
            guard let rawCurrency = balance.currency,
                  let total = balance.totalBalance?.value,
                  total.isFinite else {
                return nil
            }
            let currency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currency.isEmpty else { return nil }
            return (currency: currency, total: total)
        }
        guard !validBalances.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "DeepSeek 返回中缺少可解析的余额条目")
        }
        let selectedBalance = validBalances.first { $0.currency.uppercased() == "USD" }
            ?? validBalances[0]
        return UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额",
                used: 0,
                limit: selectedBalance.total,
                resetAt: nil,
                unit: .currency(code: selectedBalance.currency, scale: 1),
                kind: .balance
            )
        ])
    }
}

// MARK: - 响应类型

private struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool?
    let balanceInfos: [DeepSeekBalance]?

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalance: Decodable {
    let currency: String?
    let totalBalance: FlexibleNumber?
    let grantedBalance: FlexibleNumber?
    let toppedUpBalance: FlexibleNumber?

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}
