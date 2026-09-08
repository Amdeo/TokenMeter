import Foundation

// MARK: - 定义

@MainActor
struct DeepSeekProviderDefinition: ProviderDefinition {
    let id = ProviderID.deepSeek

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "DeepSeek",
            iconResourceName: "icon-deepseek",
            fallbackSystemImage: "bubble.left.and.bubble.right.fill",
            tintRGB: 0x0A84FF,
            iconInsetFraction: 0.08,
            capabilityDescription: "支持余额接口，可使用 API Key。",
            authPageURL: URL(string: "https://platform.deepseek.com/api_keys"),
            homepageURL: URL(string: "https://platform.deepseek.com"),
            authenticationSummary: "API Key · 支持余额接口"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台")]
    }

    let cardRenderer: any ProviderCardRenderer = BalanceCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        DeepSeekUsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(name: "可用余额", used: 0, limit: 28.40, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)
        ])
    }
}

// MARK: - 用量提供者

struct DeepSeekUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let response: DeepSeekBalanceResponse = try await APIClient.get(
            URL(string: "https://api.deepseek.com/user/balance")!,
            providerID: subscription.providerID,
            authorization: "Bearer \(key)"
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
