import Foundation

// MARK: - 定义

@MainActor
struct SiyuProviderDefinition: ProviderDefinition {
    let id = ProviderID.siyu

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "Siyu API",
            iconResourceName: "icon-siyu",
            fallbackSystemImage: "bolt.fill",
            tintRGB: 0x6366F1,
            capabilityDescription: "支持账户余额与订阅额度，可通过网页登录态获取。",
            authPageURL: URL(string: "https://siyu.site/login"),
            homepageURL: URL(string: "https://siyu.site"),
            authenticationSummary: "网页登录态 · 余额 + 订阅"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(
            id: .siyuBrowserSession,
            flowID: .browserSession,
            title: "网页登录态",
            systemImage: "globe",
            tintRGB: 0x6366F1,
            detail: "登录 Siyu API 账号（内置）"
        )]
    }

    let cardRenderer: any ProviderCardRenderer = SiyuCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        SiyuUsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        let balance = Quota(
            name: "可用余额",
            used: 0,
            limit: 19.39,
            resetAt: nil,
            unit: .currency(code: SiyuSite.currencyCode, scale: 1),
            kind: .balance
        )
        let sub1 = Quota(
            name: "DeepSeek大月卡",
            used: 2472,
            limit: 35000,
            resetAt: nil,
            expiresAt: now.addingTimeInterval(24 * 86400),
            unit: .currency(code: SiyuSite.currencyCode, scale: 1),
            kind: .generic
        )
        let sub2 = Quota(
            name: "DeepSeek月卡",
            used: 12055,
            limit: 17500,
            resetAt: nil,
            expiresAt: now.addingTimeInterval(3 * 86400),
            unit: .currency(code: SiyuSite.currencyCode, scale: 1),
            kind: .generic
        )
        return .realtime(subscription: subscription, quotas: [balance, sub1, sub2])
    }
}

// MARK: - 站点常量

/// Siyu API 站点常量：API 前缀与登录页。
enum SiyuSite: Sendable {
    static let apiBase = URL(string: "https://siyu.site/api/v1")!
    static let loginPageURL = URL(string: "https://siyu.site/login")!
    static let homePageURL = URL(string: "https://siyu.site")!
    /// 余额/订阅额度单位：接口返回值即美元金额，scale 为 1。
    static let currencyCode = "USD"
}

// MARK: - 用量提供者

struct SiyuUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let stored = credentials.browserCredential(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let configuration = BrowserSessionFlow.Configuration(
            providerID: subscription.providerID,
            subscriptionID: subscription.id,
            credentials: credentials,
            isUsable: { $0.expiresAt.timeIntervalSinceNow > 300 },
            refresh: SiyuSessionRefresher.refresh,
            isInvalid: { ($0 as? SiyuBrowserCredentialError)?.indicatesInvalidCredential ?? false },
            invalidMessage: "Siyu API 网页登录态已过期，请在订阅设置中重新登录"
        )
        return try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: stored,
            fetch: { try await fetchAll(credential: $0) }
        )
    }

    /// 同时拉取余额 + 活动订阅，合并为一个快照。
    /// 订阅只保留有效项：status 必须为 active 且到期时间晚于当前时间（过期订阅排除）。
    private func fetchAll(credential: KimiBrowserCredential) async throws -> UsageSnapshot {
        let me: MeResponse = try await APIClient.get(
            SiyuSite.apiBase.appendingPathComponent("/auth/me"),
            providerID: subscription.providerID,
            authorization: "\(credential.tokenType) \(credential.accessToken)"
        )
        let subscriptions: SubscriptionsResponse = try await APIClient.get(
            SiyuSite.apiBase.appendingPathComponent("/subscriptions/active"),
            providerID: subscription.providerID,
            authorization: "\(credential.tokenType) \(credential.accessToken)"
        )

        var quotas: [Quota] = []
        if let balance = me.data?.balance {
            quotas.append(Quota(
                name: "可用余额",
                used: 0,
                limit: balance,
                resetAt: nil,
                unit: .currency(code: SiyuSite.currencyCode, scale: 1),
                kind: .balance
            ))
        }
        for item in SiyuUsageProvider.activeSubscriptions(subscriptions.data ?? [], now: .now) {
            quotas.append(Quota(
                name: item.name,
                used: item.used,
                limit: item.limit,
                resetAt: nil,
                expiresAt: item.expiresAt,
                unit: .currency(code: SiyuSite.currencyCode, scale: 1),
                kind: .generic
            ))
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Siyu API 返回中没有可用数据")
        }
        return .realtime(subscription: subscription, quotas: quotas)
    }

    /// 有效订阅的展示信息：换算与标题清洗后的安全值。
    struct ActiveSubscription: Sendable, Equatable {
        let name: String
        let used: Double
        let limit: Double
        let expiresAt: Date
    }

    /// 过滤活动订阅：status == "active" 且到期时间在未来。
    /// 服务端 `/subscriptions/active` 已过滤，这里作为本地双保险，排除过期的订阅数据。
    static func activeSubscriptions(_ items: [SubscriptionsResponse.Item], now: Date) -> [ActiveSubscription] {
        items.compactMap { item in
            guard item.status == "active",
                  let raw = item.expiresAt,
                  let expiresAt = SiyuDate.parse(raw),
                  expiresAt > now else { return nil }
            return ActiveSubscription(
                name: item.group?.name ?? "订阅",
                used: item.monthlyUsageUSD,
                limit: item.group?.monthlyLimitUSD ?? 0,
                expiresAt: expiresAt
            )
        }
    }
}

// MARK: - 日期解析

/// Siyu API 的 ISO8601 时间解析（带小数秒与 UTC 偏移，如 `2026-10-07T16:34:37.662424+08:00`）。
enum SiyuDate {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - 响应类型

/// `GET /api/v1/auth/me` 响应。
private struct MeResponse: Decodable {
    struct Data: Decodable {
        let balance: Double
    }

    let code: Int
    let data: Data?
}

/// `GET /api/v1/subscriptions/active` 响应。
struct SubscriptionsResponse: Decodable {
    struct Item: Decodable {
        struct Group: Decodable {
            let name: String?
            let monthlyLimitUSD: Double?

            enum CodingKeys: String, CodingKey {
                case name
                case monthlyLimitUSD = "monthly_limit_usd"
            }
        }

        let status: String
        let monthlyUsageUSD: Double
        let expiresAt: String?
        let group: Group?

        enum CodingKeys: String, CodingKey {
            case status
            case monthlyUsageUSD = "monthly_usage_usd"
            case expiresAt = "expires_at"
            case group
        }
    }

    let code: Int
    let data: [Item]?
}
