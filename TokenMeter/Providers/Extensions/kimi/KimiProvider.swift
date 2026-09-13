import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let kimi = ProviderID(rawValue: "kimi")
}

extension AuthMethodID {
    static let kimiDeviceOAuth = AuthMethodID(rawValue: "kimi-device-oauth")
    static let kimiBrowserSession = AuthMethodID(rawValue: "kimi-browser-session")
}

// MARK: - 定义

struct KimiProviderDefinition: ProviderDefinition {
    let id = ProviderID.kimi

    /// 旧 `Platform` 枚举里的名字。
    var legacyPlatformNames: [String] { ["Kimi"] }

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "Kimi",
            iconResourceName: "icon-kimi",
            fallbackSystemImage: "moon.stars.fill",
            tintRGB: 0x5E5CE6,
            capabilityDescription: "支持 Kimi For Coding 订阅额度、网页登录态和 API Key。",
            authPageURL: URL(string: "https://platform.moonshot.cn/console/api-keys"),
            homepageURL: URL(string: "https://www.kimi.com"),
            authenticationSummary: "API Key、Kimi Code OAuth 或网页登录态",
            overallUsageLabel: "总使用量"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [
            AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台"),
            AuthMethodDefinition(
                id: .kimiDeviceOAuth, flowID: .deviceOAuth, title: "Kimi Code OAuth",
                systemImage: "lock.shield.fill", tintRGB: 0x5E5CE6, detail: "实验性设备授权",
                deviceAuthorization: .kimiCode, legacyIDs: ["kimiOAuth"]
            ),
            AuthMethodDefinition(
                id: .kimiBrowserSession, flowID: .browserSession, title: "网页登录态",
                systemImage: "globe", tintRGB: 0x32D74B, detail: "登录 Kimi 账号（内置）",
                loginRecipe: BrowserTokenSite.kimi.loginRecipe, legacyIDs: ["kimiBrowserSession"]
            ),
        ]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { KimiCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        KimiUsageProvider(subscription: subscription)
    }

}

// MARK: - 用量提供者

struct KimiUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    // Coding API（API Key / Kimi Code OAuth）使用 kimi_cli 平台头；
    // 网页登录态不能复用这组头或这个接口，实测会被 API 以 401 拒绝。
    private static let commonHeaders: [String: String] = [
        "User-Agent": "KimiCLI/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")",
        "X-Msh-Platform": "kimi_cli",
        "X-Msh-Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
        "X-Msh-Device-Name": Host.current().localizedName ?? "TokenMeter",
        "X-Msh-Device-Model": "macOS",
        "X-Msh-Os-Version": ProcessInfo.processInfo.operatingSystemVersionString,
        "X-Msh-Device-Id": UUID().uuidString.replacingOccurrences(of: "-", with: "")
    ]

    // 网页登录态只调用 www.kimi.com 的订阅统计接口，认证依赖网页登录态
    // token 与 web 平台头；该接口同时返回 5 小时、7 天和总使用量。
    private static let browserHeaders: [String: String] = [
        "X-Msh-Platform": "web",
        "X-Msh-Version": "2.1.0",
        "X-Msh-Device-Id": "TokenMeter",
        "X-Msh-Session-Id": UUID().uuidString,
        "X-Language": "zh-CN",
        "R-Timezone": "Asia/Shanghai"
    ]

    func fetchUsage() async throws -> UsageSnapshot {
        // 认证方式决定上游数据源：API Key / OAuth 走 Coding API，
        // 网页登录态走 kimi.com 的订阅统计 API，二者不能混用凭证或请求头。
        switch subscription.authMethodID {
        case .apiKey:
            // Coding API 是 API Key 的主数据源；接口拒绝时才回退到余额接口。
            guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
                throw UsageProviderError.notConfigured(subscription.providerID)
            }
            do {
                return try await fetchCodingUsage(authorization: "Bearer \(key)")
            } catch UsageProviderError.httpStatus(let status) where [401, 403, 404].contains(status) {
                return try await fetchBalance(key: key)
            }
        case .kimiDeviceOAuth:
            // OAuth 凭证只用于 Coding API；过期时先刷新，再请求 Coding 用量。
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
                    // 订阅可能已被删除/切换认证：写入前检查取消状态，防止回写陈旧凭证。
                    try Task.checkCancellation()
                    try credentials.save(oauthCredential: activeCredential, for: subscription.id)
                    didRefresh = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch KimiOAuthError.requestFailed, KimiOAuthError.timedOut {
                    throw UsageProviderError.requestFailed(
                        subscription.providerID, "Kimi Code OAuth 刷新失败，请检查网络后重试"
                    )
                } catch KimiOAuthError.httpStatus(let status) where status >= 500 {
                    throw UsageProviderError.requestFailed(
                        subscription.providerID, "Kimi OAuth 服务暂时不可用（HTTP \(status)）"
                    )
                } catch {
                    throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi Code OAuth 凭证已失效，请重新授权")
                }
            } else {
                activeCredential = credential
                didRefresh = false
            }
            return try await fetchOAuthUsage(credential: activeCredential, didRefresh: didRefresh)
        case .kimiBrowserSession:
            // 浏览器 token 只用于网页订阅统计接口，不调用 Coding API。
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
                // 写入前检查取消状态：订阅可能已被删除或切换认证方式。
                try Task.checkCancellation()
                try credentials.save(oauthCredential: refreshed, for: subscription.id)
                return try await fetchOAuthUsage(credential: refreshed, didRefresh: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch KimiOAuthError.requestFailed, KimiOAuthError.timedOut {
                throw UsageProviderError.requestFailed(
                    subscription.providerID, "Kimi Code OAuth 刷新失败，请检查网络后重试"
                )
            } catch KimiOAuthError.httpStatus(let status) where status >= 500 {
                throw UsageProviderError.requestFailed(
                    subscription.providerID, "Kimi OAuth 服务暂时不可用（HTTP \(status)）"
                )
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Kimi Code OAuth 凭证已失效，请重新授权")
            }
        }
    }

    /// API Key / Kimi Code OAuth 共用的 Coding API 请求。
    /// `limits`/`usage` 提供 Coding 窗口额度，`boosterWallet` 提供加油包数据；
    /// 网页登录态不调用此接口，因为网页 token 对该端点没有访问权限。
    private func fetchCodingUsage(authorization: String) async throws -> UsageSnapshot {
        let response: KimiUsagesResponse = try await APIClient.get(
            URL(string: "https://api.kimi.com/coding/v1/usages")!,
            providerID: subscription.providerID,
            authorization: authorization,
            headers: Self.commonHeaders,
            statusPolicy: .raw
        )
        return try Self.parseCodingUsage(response, subscription: subscription)
    }

    /// 对应 kimi.com/settings/subscription?tab=quota 的业务请求。
    /// GetSubscriptionStats 是网页登录态的唯一数据源，直接提供 5 小时、7 天和总使用量。
    private func fetchBrowserUsage(credential: BrowserTokenCredential) async throws -> UsageSnapshot {
        let authorization = "\(credential.tokenType) \(credential.accessToken)"
        let response: KimiSubscriptionStatsResponse = try await APIClient.post(
            URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!,
            providerID: subscription.providerID,
            authorization: authorization,
            headers: Self.browserHeaders,
            statusPolicy: .raw
        )
        // 网页额度页只请求 GetSubscriptionStats；5 小时窗口的零值由该响应的
        // ratelimitCode5h.enabled=true + 缺省 ratio 表示，不能再用 coding 接口覆盖它。
        return try Self.parseSubscriptionStats(response, subscription: subscription)
    }

    private func fetchBalance(key: String) async throws -> UsageSnapshot {
        let response: KimiBalanceResponse = try await APIClient.get(
            URL(string: "https://api.moonshot.cn/v1/users/me/balance")!,
            providerID: subscription.providerID,
            authorization: "Bearer \(key)",
            statusPolicy: .raw
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

    /// Coding API 响应映射：`usage` 为每周额度，`limits` 按时间窗口识别额度，
    /// `boosterWallet` 映射加油包余额与月消费。
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

    /// 网页订阅接口字段映射：
    /// `ratelimitCode5h` → 5 小时额度，`ratelimitCode7d` → 每周额度，
    /// `subscriptionBalance.amountUsedRatio` → 顶部总使用量。
    static func parseSubscriptionStats(
        _ response: KimiSubscriptionStatsResponse,
        subscription: Subscription
    ) throws -> UsageSnapshot {
        var quotas: [Quota] = []
        let weeklyRatio = normalizedRatio(response.ratelimitCode7d?.ratio?.value)
        if let weeklyRatio {
            quotas.append(Quota(name: "每周额度", used: weeklyRatio, limit: 1, resetAt: date(from: response.ratelimitCode7d?.resetTime), kind: .weekly))
        } else if response.ratelimitCode7d?.enabled == true {
            quotas.append(Quota(name: "每周额度", used: 0, limit: 1, resetAt: date(from: response.ratelimitCode7d?.resetTime), kind: .weekly))
        }
        if let fiveHourWindow = response.ratelimitCode5h,
           fiveHourWindow.enabled != false {
            // Kimi 会省略 proto3 零值：窗口对象存在但 ratio/enabled 均缺失时，视为 0%。
            let ratio = normalizedRatio(fiveHourWindow.ratio?.value)
            if fiveHourWindow.ratio?.value == nil || ratio != nil {
                quotas.append(Quota(name: "5 小时额度", used: ratio ?? 0, limit: 1, resetAt: date(from: fiveHourWindow.resetTime), kind: .fiveHour))
            }
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
    /// refresh_token 换新；401/403 时再刷新一次兑底（通用流程见 BrowserSessionFlow）。
    private func fetchBrowserSessionUsage() async throws -> UsageSnapshot {
        guard let stored = credentials.browserCredential(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let configuration = BrowserSessionFlow.Configuration(
            providerID: subscription.providerID,
            subscriptionID: subscription.id,
            credentials: credentials,
            providerName: BrowserTokenSite.kimi.displayName,
            isUsable: { $0.expiresAt.timeIntervalSinceNow > 300 },
            refresh: ChromeSessionImporter.refresh
        )
        return try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: stored,
            fetch: { try await fetchBrowserUsage(credential: $0) }
        )
    }
}

// MARK: - 响应类型

/// `GET https://api.kimi.com/coding/v1/usages` 的响应。
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

/// `POST https://www.kimi.com/.../MembershipService/GetSubscriptionStats` 的响应；
/// 网页额度页的 5 小时、7 天和总使用量都从这里读取。
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
