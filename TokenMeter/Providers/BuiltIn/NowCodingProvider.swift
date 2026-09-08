import Foundation

// MARK: - 定义

@MainActor
struct NowCodingProviderDefinition: ProviderDefinition {
    let id = ProviderID.nowCoding

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "NowCoding",
            iconResourceName: "icon-nowcoding",
            fallbackSystemImage: "flame.fill",
            tintRGB: 0x6E6CF0,
            capabilityDescription: "支持账户余额与订阅额度，可通过网页登录态获取。",
            authPageURL: NowCodingSite.loginPageURL,
            homepageURL: NowCodingSite.homePageURL,
            authenticationSummary: "网页登录态 · 余额 + 订阅"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(
            id: .nowCodingBrowserSession,
            flowID: .browserSession,
            title: "网页登录态",
            systemImage: "globe",
            tintRGB: 0x6E6CF0,
            detail: "登录 NowCoding 账号（内置）"
        )]
    }

    let cardRenderer: any ProviderCardRenderer = NowCodingCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        NowCodingUsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        let balance = Quota(
            name: "可用余额",
            used: 0,
            limit: 19.39,
            resetAt: nil,
            unit: .currency(code: "CNY", scale: 1),
            kind: .balance
        )
        let sub1 = Quota(
            name: "Codex 月卡 1500$",
            used: 10.58,
            limit: 50,
            resetAt: now.addingTimeInterval(8 * 3600),
            expiresAt: now.addingTimeInterval(26 * 86400),
            unit: .currency(code: "CNY", scale: 1),
            kind: .generic
        )
        let sub2 = Quota(
            name: "Codex 月卡 900$",
            used: 29.97,
            limit: 30,
            resetAt: now.addingTimeInterval(8 * 3600),
            expiresAt: now.addingTimeInterval(20 * 86400),
            unit: .currency(code: "CNY", scale: 1),
            kind: .generic
        )
        return .realtime(subscription: subscription, quotas: [balance, sub1, sub2])
    }
}

// MARK: - 站点常量

/// NowCoding 站点常量：API 前缀与登录页。
enum NowCodingSite: Sendable {
    static let apiBase = URL(string: "https://nowcoding.ai/api")!
    static let loginPageURL = URL(string: "https://nowcoding.ai/login")!
    static let homePageURL = URL(string: "https://nowcoding.ai")!
    /// 余额/订阅额度换算：quota / quotaPerUnit = 显示金额（站点 quota_display_type=CNY）。
    static let quotaPerUnit: Double = 500_000
    /// session cookie 名称（HttpOnly，需从 WKWebsiteDataStore 读取）。
    static let sessionCookieName = "session"
    /// 认证头名称（new-api 新版）。
    static let userHeaderName = "New-Api-User"
    static let cookieHeaderName = "Cookie"
}

// MARK: - 用量提供者

struct NowCodingUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let stored = credentials.cookieSession(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        do {
            return try await fetchAll(credential: stored)
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            throw UsageProviderError.authenticationRequired(subscription.providerID, "NowCoding 网页登录态已过期，请在订阅设置中重新登录")
        }
    }

    /// 同时拉取余额 + 订阅额度，合并为一个快照。
    private func fetchAll(credential: CookieSessionCredential) async throws -> UsageSnapshot {
        let headers = [
            NowCodingSite.cookieHeaderName: credential.sessionCookie,
            NowCodingSite.userHeaderName: credential.userID,
        ]
        let me: MeResponse = try await APIClient.get(
            NowCodingSite.apiBase.appendingPathComponent("user/self"),
            providerID: subscription.providerID,
            authorization: "",
            headers: headers
        )
        let subscriptions: SubscriptionResponse = try await APIClient.get(
            NowCodingSite.apiBase.appendingPathComponent("subscription/self"),
            providerID: subscription.providerID,
            authorization: "",
            headers: headers
        )

        var quotas: [Quota] = []
        // me.data 缺失表示余额未知：不应把未知数据显示成 0 余额。
        if let quotaValue = me.data?.quota {
            let balance = quotaValue / NowCodingSite.quotaPerUnit
            quotas.append(Quota(
                name: "可用余额",
                used: 0,
                limit: balance,
                resetAt: nil,
                unit: .currency(code: "CNY", scale: 1),
                kind: .balance
            ))
        }

        for item in subscriptions.data?.activeSubscriptions ?? [] {
            let limit = item.amountTotal / NowCodingSite.quotaPerUnit
            let used = item.amountUsed / NowCodingSite.quotaPerUnit
            quotas.append(Quota(
                name: item.shortTitle,
                used: used,
                limit: limit,
                resetAt: item.resetAt,
                expiresAt: item.expiresAt,
                unit: .currency(code: "CNY", scale: 1),
                kind: .generic
            ))
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "NowCoding 返回中没有可用数据")
        }
        return .realtime(subscription: subscription, quotas: quotas)
    }
}

// MARK: - 响应类型

/// `GET /api/user/self` 响应。
private struct MeResponse: Decodable {
    struct Data: Decodable {
        let quota: Double
    }

    let data: Data?
}

/// `GET /api/subscription/self` 响应。
private struct SubscriptionResponse: Decodable {
    struct Data: Decodable {
        struct SubscriptionItem: Decodable {
            struct Subscription: Decodable {
                let amountTotal: Double
                let amountUsed: Double
                let nextResetTime: Double?
                let endTime: Double?
                let status: String

                enum CodingKeys: String, CodingKey {
                    case amountTotal = "amount_total"
                    case amountUsed = "amount_used"
                    case nextResetTime = "next_reset_time"
                    case endTime = "end_time"
                    case status
                }
            }

            let subscription: Subscription
            let planTitle: String?

            enum CodingKeys: String, CodingKey {
                case subscription
                case planTitle = "plan_title"
            }
        }

        var activeSubscriptions: [PlanDisplay] {
            guard let items = self.subscriptions else { return [] }
            return items
                .filter { $0.subscription.status == "active" }
                .map { PlanDisplay(item: $0) }
        }

        let subscriptions: [SubscriptionItem]?

        enum CodingKeys: String, CodingKey {
            case subscriptions
        }
    }

    let data: Data?
}

/// 订阅展示信息：金额换算与标题清洗后的安全值。
struct PlanDisplay: Sendable, Equatable {
    let shortTitle: String
    let amountTotal: Double
    let amountUsed: Double
    let resetAt: Date?
    let expiresAt: Date?

    fileprivate init(item: SubscriptionResponse.Data.SubscriptionItem) {
        // 标题形如【畅享套餐】Codex 月卡 1500$（全角【】），取 】 后的核心名。
        let title = item.planTitle ?? ""
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let core = trimmed.split(separator: "】").last {
            shortTitle = String(core).trimmingCharacters(in: .whitespaces)
        } else if let core = trimmed.split(separator: "]").last {
            shortTitle = String(core).trimmingCharacters(in: .whitespaces)
        } else {
            shortTitle = trimmed
        }
        amountTotal = item.subscription.amountTotal
        amountUsed = item.subscription.amountUsed
        if let resetTime = item.subscription.nextResetTime, resetTime > 0 {
            resetAt = Date(timeIntervalSince1970: resetTime)
        } else {
            resetAt = nil
        }
        if let endTime = item.subscription.endTime, endTime > 0 {
            expiresAt = Date(timeIntervalSince1970: endTime)
        } else {
            expiresAt = nil
        }
    }
}