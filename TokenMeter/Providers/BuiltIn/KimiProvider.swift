import Foundation

// MARK: - 定义

@MainActor
struct KimiProviderDefinition: ProviderDefinition {
    let id = ProviderID.kimi

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "Kimi",
            iconResourceName: "icon-kimi",
            fallbackSystemImage: "moon.stars.fill",
            tintRGB: 0x5E5CE6,
            capabilityDescription: "支持 Kimi For Coding 订阅额度、网页登录态和 API Key。",
            authPageURL: URL(string: "https://platform.moonshot.cn/console/api-keys"),
            authenticationSummary: "API Key、Kimi Code OAuth 或网页登录态",
            overallUsageLabel: "总使用量"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [
            AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台"),
            AuthMethodDefinition(id: .kimiDeviceOAuth, flowID: .deviceOAuth, title: "Kimi Code OAuth", systemImage: "lock.shield.fill", tintRGB: 0x5E5CE6, detail: "实验性设备授权"),
            AuthMethodDefinition(id: .kimiBrowserSession, flowID: .browserSession, title: "网页登录态", systemImage: "globe", tintRGB: 0x32D74B, detail: "登录 Kimi 账号（内置）"),
        ]
    }

    let cardRenderer: any ProviderCardRenderer = KimiCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        KimiUsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        .realtime(
            subscription: subscription,
            quotas: [
                Quota(name: "5 小时额度", used: 320_000, limit: 1_000_000, resetAt: now.addingTimeInterval(2 * 3_600), kind: .fiveHour),
                Quota(name: "每周额度", used: 1_200_000, limit: 2_000_000, resetAt: now.addingTimeInterval(5 * 86_400), kind: .weekly)
            ],
            overallUsageRatio: 0.41
        )
    }
}

// MARK: - 用量提供者

struct KimiUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    private static let commonHeaders: [String: String] = [
        "User-Agent": "KimiCLI/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")",
        "X-Msh-Platform": "kimi_cli",
        "X-Msh-Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
        "X-Msh-Device-Name": Host.current().localizedName ?? "TokenMeter",
        "X-Msh-Device-Model": "macOS",
        "X-Msh-Os-Version": ProcessInfo.processInfo.operatingSystemVersionString,
        "X-Msh-Device-Id": UUID().uuidString.replacingOccurrences(of: "-", with: "")
    ]

    private static let browserHeaders: [String: String] = [
        "X-Msh-Platform": "web",
        "X-Msh-Version": "2.1.0",
        "X-Msh-Device-Id": "TokenMeter",
        "X-Msh-Session-Id": UUID().uuidString,
        "X-Language": "zh-CN",
        "R-Timezone": "Asia/Shanghai"
    ]

    func fetchUsage() async throws -> UsageSnapshot {
        switch subscription.authMethodID {
        case .apiKey:
            guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
                throw UsageProviderError.notConfigured(subscription.providerID)
            }
            do {
                return try await fetchCodingUsage(authorization: "Bearer \(key)")
            } catch UsageProviderError.httpStatus(let status) where [401, 403, 404].contains(status) {
                return try await fetchBalance(key: key)
            }
        case .kimiDeviceOAuth:
            guard let credential = credentials.oauthCredential(for: subscription.id) else {
                throw UsageProviderError.notConfigured(subscription.providerID)
            }
            let activeCredential: OAuthCredential
            let didRefresh: Bool
            if credentials.isExpiringSoon(credential) {
                guard !credential.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi Code OAuth 凭证已失效，请重新授权")
                }
                do {
                    activeCredential = try await KimiOAuthService().refresh(credential)
                    try credentials.save(oauthCredential: activeCredential, for: subscription.id)
                    didRefresh = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi Code OAuth 凭证已失效，请重新授权")
                }
            } else {
                activeCredential = credential
                didRefresh = false
            }
            return try await fetchOAuthUsage(credential: activeCredential, didRefresh: didRefresh)
        case .kimiBrowserSession:
            return try await fetchBrowserSessionUsage()
        default:
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
    }

    private func fetchOAuthUsage(credential: OAuthCredential, didRefresh: Bool) async throws -> UsageSnapshot {
        do {
            return try await fetchCodingUsage(authorization: "\(credential.tokenType) \(credential.accessToken)")
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            guard !didRefresh, !credential.refreshToken.isEmpty else {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi Code OAuth 凭证已失效，请重新授权")
            }
            do {
                let refreshed = try await KimiOAuthService().refresh(credential)
                try credentials.save(oauthCredential: refreshed, for: subscription.id)
                return try await fetchOAuthUsage(credential: refreshed, didRefresh: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi Code OAuth 凭证已失效，请重新授权")
            }
        }
    }

    private func fetchCodingUsage(authorization: String) async throws -> UsageSnapshot {
        let response: KimiUsagesResponse = try await APIClient.get(
            URL(string: "https://api.kimi.com/coding/v1/usages")!,
            providerID: subscription.providerID,
            authorization: authorization,
            headers: Self.commonHeaders
        )
        return try Self.parseCodingUsage(response, subscription: subscription)
    }

    private func fetchBrowserUsage(credential: KimiBrowserCredential) async throws -> UsageSnapshot {
        let authorization = "\(credential.tokenType) \(credential.accessToken)"
        let response: KimiSubscriptionStatsResponse = try await APIClient.post(
            URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!,
            providerID: subscription.providerID,
            authorization: authorization,
            headers: Self.browserHeaders
        )
        var fiveHourQuota: Quota?
        do {
            let codingResponse: KimiUsagesResponse = try await APIClient.get(
                URL(string: "https://api.kimi.com/coding/v1/usages")!,
                providerID: subscription.providerID,
                authorization: authorization,
                headers: Self.commonHeaders
            )
            fiveHourQuota = try Self.parseCodingUsage(codingResponse, subscription: subscription).quotas.first { $0.kind == .fiveHour }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            fiveHourQuota = nil
        }
        return try Self.parseSubscriptionStats(response, subscription: subscription, fiveHourQuota: fiveHourQuota)
    }

    private func fetchBalance(key: String) async throws -> UsageSnapshot {
        let response: KimiBalanceResponse = try await APIClient.get(
            URL(string: "https://api.moonshot.cn/v1/users/me/balance")!,
            providerID: subscription.providerID,
            authorization: "Bearer \(key)"
        )
        let balances = [
            ("可用余额", response.data.availableBalance),
            ("代金券余额", response.data.voucherBalance),
            ("现金余额", response.data.cashBalance)
        ]
        guard balances.contains(where: { $0.1.value != nil }) else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Kimi 返回中缺少余额字段")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: balances.compactMap { name, amount in
            guard let value = amount.value, value >= 0 else { return nil }
            return Quota(name: name, used: 0, limit: value, resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance)
        })
    }

    static func parseCodingUsage(_ response: KimiUsagesResponse, subscription: Subscription) throws -> UsageSnapshot {
        let limits = response.limits ?? []
        let weeklyUsage = response.usage.flatMap { usage -> Quota? in
            guard let values = quotaValues(from: usage) else {
                return nil
            }
            return Quota(name: "每周额度", used: values.used, limit: values.limit, resetAt: date(from: usage.resetTime), kind: .weekly)
        }

        let windowQuotas = limits.compactMap { item -> Quota? in
            guard let detail = item.detail,
                  let values = quotaValues(from: detail) else {
                return nil
            }
            let kind = windowKind(duration: item.window?.duration?.value, unit: item.window?.timeUnit)
            return Quota(
                name: windowName(duration: item.window?.duration?.value, unit: item.window?.timeUnit),
                used: values.used,
                limit: values.limit,
                resetAt: date(from: detail.resetTime) ?? date(from: item.window?.resetTime),
                kind: kind
            )
        }

        var quotas = deduplicatedSemanticQuotas(windowQuotas)
        quotas.removeAll { $0.kind == .weekly }
        if let weeklyUsage {
            quotas.append(weeklyUsage)
        }

        let boosterQuota = response.boosterWallet.flatMap(Self.boosterQuota)
        if let boosterQuota { quotas.append(boosterQuota) }
        let monthlyChargeQuota = response.boosterWallet.flatMap(Self.monthlyChargeQuota)
        if let monthlyChargeQuota { quotas.append(monthlyChargeQuota) }

        quotas.sort { lhs, rhs in
            let lhsRank = quotaRank(lhs)
            let rhsRank = quotaRank(rhs)
            return lhsRank == rhsRank ? lhs.name < rhs.name : lhsRank < rhsRank
        }

        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Kimi For Coding 返回中没有额度数据")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: quotas)
    }

    static func parseSubscriptionStats(
        _ response: KimiSubscriptionStatsResponse,
        subscription: Subscription,
        fiveHourQuota: Quota? = nil
    ) throws -> UsageSnapshot {
        var quotas: [Quota] = []
        let weeklyRatio = normalizedRatio(response.ratelimitCode7d?.ratio?.value)
        if let weeklyRatio {
            quotas.append(Quota(name: "每周额度", used: weeklyRatio, limit: 1, resetAt: date(from: response.ratelimitCode7d?.resetTime), kind: .weekly))
        } else if response.ratelimitCode7d?.enabled == true {
            quotas.append(Quota(name: "每周额度", used: 0, limit: 1, resetAt: date(from: response.ratelimitCode7d?.resetTime), kind: .weekly))
        }
        if let fiveHourQuota {
            quotas.append(fiveHourQuota)
        } else if response.ratelimitCode5h?.enabled == true {
            let ratio = normalizedRatio(response.ratelimitCode5h?.ratio?.value) ?? 0
            quotas.append(Quota(name: "5 小时额度", used: ratio, limit: 1, resetAt: date(from: response.ratelimitCode5h?.resetTime), kind: .fiveHour))
        }
        let overallUsageRatio = normalizedRatio(response.subscriptionBalance?.amountUsedRatio?.value)
        guard !quotas.isEmpty || overallUsageRatio != nil else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Kimi 网页订阅接口返回中没有可用数据")
        }
        quotas.sort { lhs, rhs in
            let lhsRank = quotaRank(lhs)
            let rhsRank = quotaRank(rhs)
            return lhsRank == rhsRank ? lhs.name < rhs.name : lhsRank < rhsRank
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: quotas, overallUsageRatio: overallUsageRatio)
    }

    private static func quotaValues(from detail: KimiUsagesResponse.QuotaDetail) -> (used: Double, limit: Double)? {
        guard let limit = detail.limit?.value,
              limit.isFinite, limit > 0 else {
            return nil
        }
        let used = detail.used?.value ?? detail.remaining?.value.map { limit - $0 }
        guard let used, used.isFinite else { return nil }
        return (used: min(max(used, 0), limit), limit: limit)
    }

    private static func normalizedRatio(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 1)
    }

    private static func boosterQuota(_ wallet: KimiUsagesResponse.BoosterWallet) -> Quota? {
        guard wallet.balance?.type?.uppercased() == "BOOSTER",
              let amount = wallet.balance?.amount?.value,
              let amountLeft = wallet.balance?.amountLeft?.value,
              amount.isFinite, amountLeft.isFinite,
              amount >= 0, amountLeft >= 0 else {
            return nil
        }
        let currency = wallet.balance?.currency.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? wallet.currency.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? "CNY"
        let limit = amount / 1_000_000
        let remaining = min(max(0, amountLeft / 1_000_000), limit)
        return Quota(name: "额外用量余额（\(currency)）", used: limit - remaining, limit: limit, resetAt: nil, unit: .currency(code: currency, scale: 1))
    }

    private static func monthlyChargeQuota(_ wallet: KimiUsagesResponse.BoosterWallet) -> Quota? {
        guard wallet.monthlyChargeLimitEnabled == true,
              let used = wallet.monthlyUsed?.priceInCents?.value,
              let limit = wallet.monthlyChargeLimit?.priceInCents?.value,
              used.isFinite, limit.isFinite,
              used >= 0, limit > 0 else {
            return nil
        }
        let usedCurrency = wallet.monthlyUsed?.currency.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let limitCurrency = wallet.monthlyChargeLimit?.currency.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let currency = usedCurrency, currency == limitCurrency else { return nil }
        return Quota(name: "额外用量月消费（\(currency)）", used: used, limit: limit, resetAt: nil, unit: .currency(code: currency, scale: 100))
    }

    private static func quotaRank(_ quota: Quota) -> Int {
        switch quota.kind {
        case .fiveHour: return 0
        case .weekly: return 1
        case .generic where quota.unit.isCurrency: return 4
        case .balance: return 4
        case .generic: return 3
        }
    }

    private static func deduplicatedSemanticQuotas(_ quotas: [Quota]) -> [Quota] {
        var seen = Set<Quota.Kind>()
        return quotas.filter { quota in
            guard quota.kind != .generic else { return true }
            return seen.insert(quota.kind).inserted
        }
    }

    private static func windowKind(duration: Double?, unit: String?) -> Quota.Kind {
        guard let duration, duration.isFinite, duration >= 0 else { return .generic }
        let normalizedUnit = unit?.uppercased() ?? ""
        switch normalizedUnit {
        case let value where value.contains("MINUTE") && abs(duration - 300) < 0.1:
            return .fiveHour
        case let value where value.contains("HOUR") && abs(duration - 5) < 0.1:
            return .fiveHour
        case let value where value.contains("DAY") && abs(duration - 7) < 0.1:
            return .weekly
        case let value where value.contains("WEEK") && (abs(duration - 1) < 0.1 || abs(duration - 7) < 0.1):
            return .weekly
        default:
            return .generic
        }
    }

    private static func windowName(duration: Double?, unit: String?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "限额窗口" }
        let value = Int(duration)
        let normalizedUnit = unit?.uppercased() ?? ""
        switch normalizedUnit {
        case let unit where unit.contains("MINUTE"):
            return value == 300 ? "5 小时额度" : "\(value) 分钟额度"
        case let unit where unit.contains("HOUR"):
            return "\(value) 小时额度"
        case let unit where unit.contains("DAY"):
            return value == 7 ? "每周额度" : "\(value) 天额度"
        case let unit where unit.contains("WEEK"):
            return value == 1 || value == 7 ? "每周额度" : "\(value) 周额度"
        default:
            return "限额窗口"
        }
    }

    private static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

extension KimiUsageProvider {
    /// 网页登录态：access_token 有效期短（约一小时），临近/已过期时先用
    /// refresh_token 换新；401/403 时再刷新一次兑底。
    private func fetchBrowserSessionUsage() async throws -> UsageSnapshot {
        var credential: KimiBrowserCredential
        var didRefresh = false
        if let stored = credentials.browserCredential(for: subscription.id),
           stored.expiresAt.timeIntervalSinceNow > 300 {
            credential = stored
        } else {
            guard let stored = credentials.browserCredential(for: subscription.id) else {
                throw UsageProviderError.notConfigured(subscription.providerID)
            }
            do {
                credential = try await ChromeSessionImporter.refresh(stored)
                try credentials.save(browserCredential: credential, for: subscription.id)
                didRefresh = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi 网页登录态已过期，请在订阅设置中重新登录")
            }
        }
        do {
            return try await fetchBrowserUsage(credential: credential)
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            guard !didRefresh else {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi 网页登录态已过期，请在订阅设置中重新登录")
            }
            do {
                let refreshed = try await ChromeSessionImporter.refresh(credential)
                try credentials.save(browserCredential: refreshed, for: subscription.id)
                return try await fetchBrowserUsage(credential: refreshed)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi 网页登录态已过期，请在订阅设置中重新登录")
            }
        }
    }
}

// MARK: - 响应类型

struct KimiUsagesResponse: Decodable {
    struct QuotaDetail: Decodable {
        let limit: FlexibleNumber?
        let used: FlexibleNumber?
        let remaining: FlexibleNumber?
        let resetTime: String?
    }

    struct LimitWindow: Decodable {
        struct Window: Decodable {
            let duration: FlexibleNumber?
            let timeUnit: String?
            let resetTime: String?
        }
        let window: Window?
        let detail: QuotaDetail?

        enum CodingKeys: String, CodingKey {
            case window, detail
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            window = try container.decodeIfPresent(Window.self, forKey: .window)
            detail = try container.decodeIfPresent(QuotaDetail.self, forKey: .detail) ?? (try? QuotaDetail(from: decoder))
        }
    }

    struct BoosterWallet: Decodable {
        struct Balance: Decodable {
            let type: String?
            let amount: FlexibleNumber?
            let amountLeft: FlexibleNumber?
            let currency: String?

            enum CodingKeys: String, CodingKey {
                case type, amount
                case amountLeft = "amountLeft"
                case currency
            }
        }

        struct Price: Decodable {
            let priceInCents: FlexibleNumber?
            let currency: String?

            enum CodingKeys: String, CodingKey {
                case priceInCents = "priceInCents"
                case currency
            }
        }

        let balance: Balance?
        let currency: String?
        let monthlyChargeLimitEnabled: Bool?
        let monthlyUsed: Price?
        let monthlyChargeLimit: Price?
    }

    let usage: QuotaDetail?
    let limits: [LimitWindow]?
    let boosterWallet: BoosterWallet?
}

struct KimiSubscriptionStatsResponse: Decodable {
    struct RateLimit: Decodable {
        let ratio: FlexibleNumber?
        let enabled: Bool?
        let resetTime: String?
    }

    struct SubscriptionBalance: Decodable {
        let amountUsedRatio: FlexibleNumber?
        let expireTime: String?
    }

    let ratelimitCode5h: RateLimit?
    let ratelimitCode7d: RateLimit?
    let subscriptionBalance: SubscriptionBalance?
}

private struct KimiBalanceResponse: Decodable {
    let data: KimiBalance
}

private struct KimiBalance: Decodable {
    let availableBalance: FlexibleNumber
    let voucherBalance: FlexibleNumber
    let cashBalance: FlexibleNumber

    enum CodingKeys: String, CodingKey {
        case availableBalance = "available_balance"
        case voucherBalance = "voucher_balance"
        case cashBalance = "cash_balance"
    }
}
