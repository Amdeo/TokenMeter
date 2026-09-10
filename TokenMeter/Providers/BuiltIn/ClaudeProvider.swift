import Foundation

@MainActor
struct ClaudeProviderDefinition: ProviderDefinition {
    let id = ProviderID.claude

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "Claude",
            iconResourceName: nil,
            fallbackSystemImage: "asterisk",
            tintRGB: 0xD97757,
            capabilityDescription: "支持 Claude Pro/Max 订阅的 5 小时与每周额度。",
            authPageURL: URL(string: "https://claude.ai/oauth/authorize"),
            homepageURL: URL(string: "https://claude.ai"),
            authenticationSummary: "claude.ai OAuth 授权"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(
            id: .claudeOAuth,
            flowID: .oauthCode,
            title: "Claude OAuth",
            systemImage: "lock.shield.fill",
            tintRGB: 0xD97757,
            detail: "浏览器完成 claude.ai 授权后粘贴授权码"
        )]
    }

    let cardRenderer: any ProviderCardRenderer = QuotaListCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        ClaudeUsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时额度", used: 24, limit: 100, resetAt: now.addingTimeInterval(2 * 3_600), kind: .fiveHour),
            Quota(name: "每周额度", used: 61, limit: 100, resetAt: now.addingTimeInterval(4 * 86_400), kind: .weekly)
        ])
    }
}

struct ClaudeUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials: CredentialStore
    private let oauthService: ClaudeOAuthService
    private let transport: HTTPTransport

    init(
        subscription: Subscription,
        credentials: CredentialStore = CredentialStore(),
        oauthService: ClaudeOAuthService = ClaudeOAuthService(),
        transport: HTTPTransport = .live
    ) {
        self.subscription = subscription
        self.credentials = credentials
        self.oauthService = oauthService
        self.transport = transport
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 额度端点按 Claude Code CLI 指纹校验，缺少 beta 头会返回 403。
    private static var usageHeaders: [String: String] {
        [
            "anthropic-beta": ClaudeCodeFingerprint.usageBeta,
            "User-Agent": ClaudeCodeFingerprint.cliUserAgent,
            "Accept": "application/json, text/plain, */*"
        ]
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let credential = credentials.oauthCredential(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let activeCredential = try await refreshedIfNeeded(credential)
        return try await fetchUsage(credential: activeCredential, didRefresh: activeCredential != credential)
    }

    private func refreshedIfNeeded(_ credential: OAuthCredential) async throws -> OAuthCredential {
        guard credentials.isExpiringSoon(credential) else { return credential }
        guard !credential.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageProviderError.authenticationRequired(subscription.providerID, "Claude OAuth 凭证已失效，请重新授权")
        }
        return try await refreshAndSave(credential)
    }

    private func fetchUsage(credential: OAuthCredential, didRefresh: Bool) async throws -> UsageSnapshot {
        do {
            let response: ClaudeUsageResponse = try await APIClient.get(
                Self.usageURL,
                providerID: subscription.providerID,
                authorization: "\(credential.tokenType) \(credential.accessToken)",
                headers: Self.usageHeaders,
                transport: transport
            )
            return try Self.parseUsage(response, subscription: subscription)
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            guard !didRefresh, !credential.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Claude OAuth 凭证已失效，请重新授权")
            }
            do {
                let refreshed = try await refreshAndSave(credential)
                return try await fetchUsage(credential: refreshed, didRefresh: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as UsageProviderError {
                throw error
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Claude OAuth 凭证已失效，请重新授权")
            }
        } catch UsageProviderError.httpStatus(429) {
            // 额度接口按来源 IP 限流：重试只会加深限流，直接提示稍后再试。
            throw UsageProviderError.requestFailed(subscription.providerID, "额度接口被限流，请稍后重试")
        }
    }

    private func refreshAndSave(_ credential: OAuthCredential) async throws -> OAuthCredential {
        do {
            let refreshed = try await oauthService.refresh(credential)
            try Task.checkCancellation()
            try credentials.save(oauthCredential: refreshed, for: subscription.id)
            return refreshed
        } catch is CancellationError {
            throw CancellationError()
        } catch ClaudeOAuthError.networkFailed, ClaudeOAuthError.timedOut {
            throw UsageProviderError.requestFailed(subscription.providerID, "Claude OAuth 刷新失败，请检查网络后重试")
        } catch ClaudeOAuthError.httpStatus(let status) where status >= 500 || status == 429 {
            throw UsageProviderError.requestFailed(subscription.providerID, "Claude OAuth 服务暂时不可用（HTTP \(status)）")
        } catch {
            throw UsageProviderError.authenticationRequired(subscription.providerID, "Claude OAuth 凭证已失效，请重新授权")
        }
    }

    // MARK: - 响应映射

    /// 映射 `/api/oauth/usage`：`five_hour` / `seven_day` 为账户级窗口，
    /// `limits[]` 提供同名的回退与模型级每周额度，`spend`/`extra_usage` 为额外用量。
    static func parseUsage(_ response: ClaudeUsageResponse, subscription: Subscription) throws -> UsageSnapshot {
        let entries = response.limits ?? []
        var quotas: [Quota] = []

        let fiveHour = response.fiveHour ?? entries.first { $0.kind == "session" }?.bucket
        if let quota = quota(from: fiveHour, name: "5 小时额度", kind: .fiveHour) {
            quotas.append(quota)
        }

        let sevenDay = response.sevenDay ?? entries.first { $0.kind == "weekly_all" }?.bucket
        if let quota = quota(from: sevenDay, name: "每周额度", kind: .weekly) {
            quotas.append(quota)
        }

        // 旧版按模型拆分的周额度（2026-07 起恒为 null，保留以兼容仍返回它的账户）。
        for (bucket, model) in [(response.sevenDayOpus, "Opus"), (response.sevenDaySonnet, "Sonnet")] {
            if let quota = quota(from: bucket, name: "每周额度（\(model)）", kind: .generic) {
                quotas.append(quota)
            }
        }

        // 当前模型级周额度的承载方式是 `limits[]` 的 weekly_scoped + display_name。
        var seenScoped = Set<String>()
        for entry in entries where entry.kind == "weekly_scoped" {
            guard let displayName = entry.displayName, !displayName.isEmpty,
                  seenScoped.insert(displayName).inserted,
                  let quota = quota(from: entry.bucket, name: "每周额度（\(displayName)）", kind: .generic) else { continue }
            quotas.append(quota)
        }

        if let extra = extraUsageQuota(response) {
            quotas.append(extra)
        }

        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Claude 返回中没有可解析的额度数据")
        }
        quotas.sort { lhs, rhs in
            let lhsRank = quotaRank(lhs)
            let rhsRank = quotaRank(rhs)
            return lhsRank == rhsRank ? lhs.name < rhs.name : lhsRank < rhsRank
        }
        return .realtime(subscription: subscription, quotas: quotas)
    }

    /// utilization 为 0–100 的百分比，统一按 limit = 100 存放。
    private static func quota(from bucket: ClaudeUsageResponse.Bucket?, name: String, kind: Quota.Kind) -> Quota? {
        guard let utilization = bucket?.utilization?.value, utilization.isFinite else { return nil }
        return Quota(
            name: name,
            used: min(max(utilization, 0), 100),
            limit: 100,
            resetAt: date(from: bucket?.resetsAt),
            kind: kind
        )
    }

    /// 额外用量（美元）：优先用较新的 `spend`，否则回退旧版 `extra_usage`。
    private static func extraUsageQuota(_ response: ClaudeUsageResponse) -> Quota? {
        if let spend = response.spend,
           let used = amount(spend.used),
           let limit = amount(spend.limit),
           limit > 0, used >= 0 {
            return currencyQuota(name: "额外用量（\(spend.used?.currency ?? "USD")）", used: used, limit: limit, currency: spend.used?.currency)
        }
        if let extra = response.extraUsage,
           extra.isEnabled == true,
           let usedCredits = extra.usedCredits?.value,
           let monthlyLimit = extra.monthlyLimit?.value {
            let scale = pow(10, extra.decimalPlaces?.value ?? 2)
            let used = usedCredits / scale
            let limit = monthlyLimit / scale
            guard used.isFinite, limit.isFinite, used >= 0, limit > 0 else { return nil }
            return currencyQuota(name: "额外用量（\(extra.currency ?? "USD")）", used: used, limit: limit, currency: extra.currency)
        }
        return nil
    }

    private static func amount(_ money: ClaudeUsageResponse.Spend.Money?) -> Double? {
        guard let minor = money?.amountMinor?.value, minor.isFinite else { return nil }
        return minor / pow(10, money?.exponent?.value ?? 2)
    }

    private static func currencyQuota(name: String, used: Double, limit: Double, currency: String?) -> Quota {
        Quota(
            name: name,
            used: used,
            limit: limit,
            resetAt: nil,
            unit: .currency(code: currency ?? "USD", scale: 1),
            kind: .generic
        )
    }

    private static func quotaRank(_ quota: Quota) -> Int {
        switch quota.kind {
        case .fiveHour: 0
        case .weekly: 1
        default: 2
        }
    }

    private static func date(from timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) { return date }
        return ISO8601DateFormatter().date(from: timestamp)
    }
}

// MARK: - 响应类型

/// `GET https://api.anthropic.com/api/oauth/usage` 的响应。
struct ClaudeUsageResponse: Decodable {
    struct Bucket: Decodable {
        let utilization: FlexibleNumber?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }

            let model: Model?
        }

        let kind: String?
        let percent: FlexibleNumber?
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }

        var bucket: Bucket? {
            guard percent?.value != nil || resetsAt != nil else { return nil }
            return Bucket(utilization: percent, resetsAt: resetsAt)
        }

        var displayName: String? {
            let name = scope?.model?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name?.isEmpty == false) ? name : nil
        }
    }

    struct Spend: Decodable {
        struct Money: Decodable {
            let amountMinor: FlexibleNumber?
            let currency: String?
            let exponent: FlexibleNumber?

            enum CodingKeys: String, CodingKey {
                case currency, exponent
                case amountMinor = "amount_minor"
            }
        }

        let used: Money?
        let limit: Money?
    }

    struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: FlexibleNumber?
        let usedCredits: FlexibleNumber?
        let decimalPlaces: FlexibleNumber?
        let currency: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case decimalPlaces = "decimal_places"
        }
    }

    let fiveHour: Bucket?
    let sevenDay: Bucket?
    let sevenDayOpus: Bucket?
    let sevenDaySonnet: Bucket?
    let limits: [Limit]?
    let spend: Spend?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case limits, spend
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}
