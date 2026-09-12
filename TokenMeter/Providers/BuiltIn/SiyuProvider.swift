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
            authPageURL: BrowserRelayRefresher.siyu.site.loginPageURL,
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
        // 每个订阅展示 每日/每周/每月 三个窗口；重置时间按窗口起点 + 1d/7d/30d 演示。
        let sub1 = SiyuUsageProvider.windowQuotas(
            key: "demo.1",
            title: "DeepSeek大月卡",
            windows: [
                .daily(used: 370, limit: 2000, windowStart: Self.iso(now.addingTimeInterval(-20 * 3600))),
                .weekly(used: 2552, limit: 10000, windowStart: Self.iso(now.addingTimeInterval(-5 * 86400 - 4 * 3600))),
                .monthly(used: 2552, limit: 35000, windowStart: Self.iso(now.addingTimeInterval(-5 * 86400 - 4 * 3600))),
            ].compactMap { $0 },
            expiresAt: now.addingTimeInterval(25 * 86400)
        )
        let sub2 = SiyuUsageProvider.windowQuotas(
            key: "demo.2",
            title: "DeepSeek月卡",
            windows: [
                .daily(used: 0, limit: 1000, windowStart: nil),
                .weekly(used: 691, limit: 5000, windowStart: Self.iso(now.addingTimeInterval(-4 * 86400 - 2 * 3600))),
                .monthly(used: 12055, limit: 17500, windowStart: Self.iso(now.addingTimeInterval(-5 * 3600))),
            ].compactMap { $0 },
            expiresAt: now.addingTimeInterval(3 * 86400)
        )
        return .realtime(subscription: subscription, quotas: [balance] + sub1 + sub2)
    }

    /// 演示用 ISO8601 时间字符串（窗口起点）。
    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - 站点常量

/// Siyu API 站点常量：余额/订阅额度的单位。
/// API 前缀、登录页与续期入口见 `BrowserRelayRefresher.siyu`。
enum SiyuSite: Sendable {
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
            providerName: BrowserTokenSite.siyu.displayName,
            isUsable: { $0.expiresAt.timeIntervalSinceNow > 300 },
            refresh: { try await BrowserRelayRefresher.siyu.refresh($0) }
        )
        return try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: stored,
            fetch: { try await fetchAll(credential: $0) }
        )
    }

    /// 同时拉取余额 + 活动订阅，合并为一个快照。
    /// 订阅只保留有效项：status 必须为 active 且到期时间晚于当前时间（过期订阅排除）。
    /// 每个订阅展开为 每日/每周/每月 三个额度窗口，重置时间取窗口起点 + 1d/7d/30d。
    private func fetchAll(credential: KimiBrowserCredential) async throws -> UsageSnapshot {
        let me: MeResponse = try await APIClient.get(
            BrowserRelayRefresher.siyu.apiBase.appendingPathComponent("/auth/me"),
            providerID: subscription.providerID,
            authorization: "\(credential.tokenType) \(credential.accessToken)"
        )
        let subscriptions: SubscriptionsResponse = try await APIClient.get(
            BrowserRelayRefresher.siyu.apiBase.appendingPathComponent("/subscriptions/active"),
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
            quotas.append(contentsOf: Self.windowQuotas(
                key: item.key,
                title: item.name,
                windows: item.windows,
                expiresAt: item.expiresAt
            ))
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Siyu API 返回中没有可用数据")
        }
        return .realtime(subscription: subscription, quotas: quotas)
    }

    /// 把套餐的额度窗口转换为额度行。
    /// 显示名形如 "DeepSeek大月卡 · 每日"（配色与编辑页按名称取键），
    /// 分组靠独立的 `key`/`title` 元数据，卡片不再解析名称字符串。
    static func windowQuotas(key: String, title: String, windows: [UsageWindow], expiresAt: Date?) -> [Quota] {
        windows.map { window in
            Quota(
                name: "\(title) · \(window.title)",
                used: window.used,
                limit: window.limit,
                resetAt: window.resetAt,
                expiresAt: expiresAt,
                unit: .currency(code: SiyuSite.currencyCode, scale: 1),
                kind: .generic,
                group: .init(key: key, title: title)
            )
        }
    }

    /// 有效订阅的展示信息：换算与标题清洗后的安全值。
    struct ActiveSubscription: Sendable, Equatable {
        /// 分组键：同一条订阅的窗口共用，卡片按它归组（显示名可能重复，不能当身份）。
        let key: String
        let name: String
        let expiresAt: Date
        let windows: [UsageWindow]
    }

    /// 单个额度窗口（每日/每周/每月）。
    /// 服务端没给该窗口上限时 `nil`：没有上限就没有可展示的进度，
    /// 否则会被当成 0 上限、在卡片里显示成「已用尽」。
    struct UsageWindow: Sendable, Equatable {
        let title: String
        let used: Double
        let limit: Double
        let resetAt: Date?

        static func daily(used: Double, limit: Double?, windowStart: String?) -> UsageWindow? {
            make(title: "每日", used: used, limit: limit, windowStart: windowStart, days: 1)
        }

        static func weekly(used: Double, limit: Double?, windowStart: String?) -> UsageWindow? {
            make(title: "每周", used: used, limit: limit, windowStart: windowStart, days: 7)
        }

        static func monthly(used: Double, limit: Double?, windowStart: String?) -> UsageWindow? {
            make(title: "每月", used: used, limit: limit, windowStart: windowStart, days: 30)
        }

        private static func make(title: String, used: Double, limit: Double?, windowStart: String?, days: Int) -> UsageWindow? {
            guard let limit, limit > 0 else { return nil }
            return UsageWindow(title: title, used: used, limit: limit, resetAt: resetAfter(windowStart: windowStart, days: days))
        }

        /// 窗口起点 + N 天即下次重置时刻；无窗口起点（等待首次使用）时不显示重置提示。
        private static func resetAfter(windowStart: String?, days: Int) -> Date? {
            guard let raw = windowStart, let start = SiyuDate.parse(raw) else { return nil }
            return start.addingTimeInterval(Double(days) * 86_400)
        }
    }

    /// 过滤活动订阅：status == "active" 且到期时间在未来。
    /// 服务端 `/subscriptions/active` 已过滤，这里作为本地双保险，排除过期的订阅数据。
    /// 只保留服务端给出上限的窗口；一条订阅若没有任何上限，就没有可展示的进度行，整体省略。
    static func activeSubscriptions(_ items: [SubscriptionsResponse.Item], now: Date) -> [ActiveSubscription] {
        items.enumerated().compactMap { index, item in
            guard item.status == "active",
                  let raw = item.expiresAt,
                  let expiresAt = SiyuDate.parse(raw),
                  expiresAt > now else { return nil }
            let group = item.group
            let windows = [
                UsageWindow.daily(used: item.dailyUsageUSD ?? 0, limit: group?.dailyLimitUSD, windowStart: item.dailyWindowStart),
                UsageWindow.weekly(used: item.weeklyUsageUSD ?? 0, limit: group?.weeklyLimitUSD, windowStart: item.weeklyWindowStart),
                UsageWindow.monthly(used: item.monthlyUsageUSD ?? 0, limit: group?.monthlyLimitUSD, windowStart: item.monthlyWindowStart),
            ].compactMap { $0 }
            guard !windows.isEmpty else { return nil }
            return ActiveSubscription(
                key: "siyu.plan.\(index)",
                name: group?.name ?? "订阅",
                expiresAt: expiresAt,
                windows: windows
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
/// 服务端对每个订阅返回 每日/每周/每月 三个额度窗口（用量 + 窗口起点），
/// 以及 group 上的三个限额；无窗口起点表示该窗口等待首次使用。
struct SubscriptionsResponse: Decodable {
    struct Item: Decodable {
        struct Group: Decodable {
            let name: String?
            let dailyLimitUSD: Double?
            let weeklyLimitUSD: Double?
            let monthlyLimitUSD: Double?

            enum CodingKeys: String, CodingKey {
                case name
                case dailyLimitUSD = "daily_limit_usd"
                case weeklyLimitUSD = "weekly_limit_usd"
                case monthlyLimitUSD = "monthly_limit_usd"
            }
        }

        let status: String
        let dailyUsageUSD: Double?
        let weeklyUsageUSD: Double?
        let monthlyUsageUSD: Double?
        let dailyWindowStart: String?
        let weeklyWindowStart: String?
        let monthlyWindowStart: String?
        let expiresAt: String?
        let group: Group?

        enum CodingKeys: String, CodingKey {
            case status
            case dailyUsageUSD = "daily_usage_usd"
            case weeklyUsageUSD = "weekly_usage_usd"
            case monthlyUsageUSD = "monthly_usage_usd"
            case dailyWindowStart = "daily_window_start"
            case weeklyWindowStart = "weekly_window_start"
            case monthlyWindowStart = "monthly_window_start"
            case expiresAt = "expires_at"
            case group
        }
    }

    let code: Int
    let data: [Item]?
}
