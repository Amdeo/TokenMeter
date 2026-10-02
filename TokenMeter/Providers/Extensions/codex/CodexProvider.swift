import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let codex = ProviderID(rawValue: "codex")
}

extension AuthMethodID {
    static let codexDeviceOAuth = AuthMethodID(rawValue: "codex-device-oauth")
}

struct CodexProviderDefinition: ProviderDefinition {
    let id = ProviderID.codex

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "OpenAI Codex",
            iconResourceName: "icon-codex",
            fallbackSystemImage: "chevron.left.forwardslash.chevron.right",
            tintRGB: 0x10A37F,
            railMarkResource: "openai",
            capabilityDescription: "支持 OpenAI Codex 订阅额度。",
            authPageURL: URL(string: "https://auth.openai.com/codex/device"),
            homepageURL: URL(string: "https://chatgpt.com"),
            authenticationSummary: "Codex 设备 OAuth"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .codexDeviceOAuth, flowID: .deviceOAuth, title: "OpenAI Codex OAuth", systemImage: "lock.shield.fill", tintRGB: 0x10A37F, detail: "实验性，接口可能变动", deviceAuthorization: .codexCode)]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { CodexCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        CodexUsageProvider(subscription: subscription)
    }

}

struct CodexUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials: CredentialStore
    private let oauthService: CodexOAuthService
    private let transport: HTTPTransport

    init(
        subscription: Subscription,
        credentials: CredentialStore = CredentialStore(),
        oauthService: CodexOAuthService = CodexOAuthService(),
        transport: HTTPTransport = .live
    ) {
        self.subscription = subscription
        self.credentials = credentials
        self.oauthService = oauthService
        self.transport = transport
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let credential = credentials.oauthCredential(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        guard let accountID = credential.accountID,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageProviderError.authenticationRequired(subscription.providerID, "Codex OAuth 凭证已失效，请重新授权")
        }
        let activeCredential = try await refreshedIfNeeded(credential)
        guard let activeAccountID = activeCredential.accountID else {
            throw UsageProviderError.authenticationRequired(subscription.providerID, "Codex OAuth 凭证已失效，请重新授权")
        }
        return try await fetchUsage(credential: activeCredential, accountID: activeAccountID, didRefresh: activeCredential != credential)
    }

    private func refreshedIfNeeded(_ credential: OAuthCredential) async throws -> OAuthCredential {
        guard credentials.isExpiringSoon(credential) else { return credential }
        guard !credential.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageProviderError.authenticationRequired(subscription.providerID, "Codex OAuth 凭证已失效，请重新授权")
        }
        return try await refreshAndSave(credential)
    }

    private func fetchUsage(credential: OAuthCredential, accountID: String, didRefresh: Bool) async throws -> UsageSnapshot {
        do {
            let response: CodexUsageResponse = try await APIClient.get(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                providerID: subscription.providerID,
                authorization: "\(credential.tokenType) \(credential.accessToken)",
                headers: ["ChatGPT-Account-Id": accountID],
                statusPolicy: .raw,
                transport: transport
            )
            return try Self.parseUsage(response, subscription: subscription)
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            guard !didRefresh, !credential.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Codex OAuth 凭证已失效，请重新授权")
            }
            do {
                let refreshed = try await refreshAndSave(credential)
                guard let refreshedAccountID = refreshed.accountID else {
                    throw UsageProviderError.authenticationRequired(subscription.providerID, "Codex OAuth 凭证已失效，请重新授权")
                }
                return try await fetchUsage(credential: refreshed, accountID: refreshedAccountID, didRefresh: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as UsageProviderError {
                throw error
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "Codex OAuth 凭证已失效，请重新授权")
            }
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
        } catch CodexOAuthError.networkFailed, CodexOAuthError.timedOut {
            throw UsageProviderError.requestFailed(subscription.providerID, "Codex OAuth 刷新失败，请检查网络后重试")
        } catch CodexOAuthError.httpStatus(let status) where status >= 500 || status == 429 {
            throw UsageProviderError.requestFailed(subscription.providerID, "Codex OAuth 服务暂时不可用（HTTP \(status)）")
        } catch {
            throw UsageProviderError.authenticationRequired(subscription.providerID, "Codex OAuth 凭证已失效，请重新授权")
        }
    }

    static func parseUsage(_ response: CodexUsageResponse, subscription: Subscription, now: Date = .now) throws -> UsageSnapshot {
        var quotas: [Quota] = []

        // 账号级窗口（服务端不给名字）：primary / secondary 的 kind 由窗口时长决定，不认槽位——
        // Kimi Pro 没有 5 小时窗口，账号级那一组只报一个每周窗口，所以有几行画几行。
        if let limit = response.rateLimit {
            quotas += windowQuotas(from: limit, modelName: nil, now: now)
        }

        // 按模型限额：同一套窗口结构，但服务端给了名字（`limit_name` / `metered_feature`），
        // 行名带上它，与账号级窗口区分开。
        for extra in response.additionalRateLimits ?? [] {
            guard let limit = extra.rateLimit else { continue }
            quotas += windowQuotas(from: limit, modelName: extra.displayName, now: now)
        }

        // 预付费额度：`credits` 说的是「还剩多少钱」，用余额行表达——与中转站同一条读法。
        // `unlimited` 为真时没有余额可报，不摆一行 0。
        if let credits = response.credits,
           credits.unlimited != true,
           let balance = credits.balance?.value,
           balance.isFinite {
            quotas.append(Quota(
                name: "可用额度",
                used: 0,
                limit: balance,
                resetAt: nil,
                unit: .currency(code: "USD", scale: 1),
                kind: .balance
            ))
        }

        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Codex 返回中没有可解析的额度窗口")
        }

        // 套餐名不进额度行，随快照带给自定义卡片（`providerData` 的既定用途）。
        let plan = response.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .realtime(
            subscription: subscription,
            quotas: quotas,
            providerData: plan.flatMap { $0.isEmpty ? nil : .object(["plan": .string($0)]) }
        )
    }

    /// 一组限额里的窗口，按各自时长命名；`modelName` 非空时行名带上它（按模型限额）。
    private static func windowQuotas(from limit: CodexUsageResponse.RateLimit, modelName: String?, now: Date) -> [Quota] {
        [limit.primaryWindow, limit.secondaryWindow].compactMap { window -> Quota? in
            guard let window,
                  let percentage = window.usedPercent?.value,
                  percentage.isFinite else { return nil }
            let duration = window.limitWindowSeconds?.value
            let kind: Quota.Kind
            if let duration, abs(duration - 5 * 3_600) < 1 { kind = .fiveHour }
            else if let duration, abs(duration - 7 * 86_400) < 1 { kind = .weekly }
            else { kind = .generic }
            let base = duration.map(Self.windowName) ?? "额度"
            let name = modelName.map { "\(base)（\($0)）" } ?? base
            let resetAt = window.resetAt?.value.flatMap(Self.date) ?? window.resetAfterSeconds?.value.map { now.addingTimeInterval($0) }
            return Quota(name: name, used: min(max(percentage, 0), 100), limit: 100, resetAt: resetAt, kind: kind)
        }
    }

    /// 套餐标识 → 用户认得的套餐名。认不出的原样透传：一个不认识的名字也好过没有名字
    /// （与 Pulse 的 `CodexUsageService.planName` 同一张表）。
    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "free": "Free"
        case "go": "Go"
        case "plus": "Plus"
        case "pro": "Pro"
        case "prolite": "Pro 5x"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        default: raw
        }
    }

    private static func windowName(_ seconds: Double) -> String {
        if abs(seconds - 5 * 3_600) < 1 { return "5 小时额度" }
        if abs(seconds - 7 * 86_400) < 1 { return "7 天额度" }
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 { return "\(Int(seconds / 86_400)) 天额度" }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600)) 小时额度" }
        return "\(Int(seconds / 60)) 分钟额度"
    }

    private static func date(_ epoch: Double) -> Date? {
        guard epoch.isFinite, epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1_000 : epoch)
    }
}

struct CodexUsageResponse: Decodable {
    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" }
    }
    struct Window: Decodable {
        let usedPercent: FlexibleNumber?
        let limitWindowSeconds: FlexibleNumber?
        let resetAt: FlexibleNumber?
        let resetAfterSeconds: FlexibleNumber?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"; case limitWindowSeconds = "limit_window_seconds"; case resetAt = "reset_at"; case resetAfterSeconds = "reset_after_seconds"
        }
    }
    /// 按模型限额：与账号级同一套窗口结构，另带一个名字（`limit_name`，回退 `metered_feature`）。
    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"; case meteredFeature = "metered_feature"; case rateLimit = "rate_limit"
        }
        var displayName: String? {
            let name = limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
            let feature = meteredFeature?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (feature?.isEmpty == false) ? feature : nil
        }
    }
    /// 预付费额度（`credits`）：`unlimited` 为真表示没有额度上限，`balance` 是剩余金额。
    struct Credits: Decodable {
        let unlimited: Bool?
        let balance: FlexibleNumber?
    }
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    let credits: Credits?
    let planType: String?
    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"; case additionalRateLimits = "additional_rate_limits"; case credits
        case planType = "plan_type"
    }
}
