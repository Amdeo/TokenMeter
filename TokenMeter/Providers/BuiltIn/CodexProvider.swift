import Foundation

struct CodexProviderDefinition: ProviderDefinition {
    let id = ProviderID.codex

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "OpenAI Codex",
            iconResourceName: nil,
            fallbackSystemImage: "chevron.left.forwardslash.chevron.right",
            tintRGB: 0x10A37F,
            capabilityDescription: "支持 OpenAI Codex 订阅额度。",
            authPageURL: URL(string: "https://auth.openai.com/codex/device"),
            homepageURL: URL(string: "https://chatgpt.com"),
            authenticationSummary: "Codex 设备 OAuth"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .codexDeviceOAuth, flowID: .deviceOAuth, title: "OpenAI Codex OAuth", systemImage: "lock.shield.fill", tintRGB: 0x10A37F, detail: "实验性，接口可能变动")]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { QuotaListCardRenderer() }

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
        let quotas = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow].compactMap { window -> Quota? in
            guard let window,
                  let percentage = window.usedPercent?.value,
                  percentage.isFinite else { return nil }
            let duration = window.limitWindowSeconds?.value
            let kind: Quota.Kind
            if let duration, abs(duration - 5 * 3_600) < 1 { kind = .fiveHour }
            else if let duration, abs(duration - 7 * 86_400) < 1 { kind = .weekly }
            else { kind = .generic }
            let name = duration.map(Self.windowName) ?? "额度"
            let resetAt = window.resetAt?.value.flatMap(Self.date) ?? window.resetAfterSeconds?.value.map { now.addingTimeInterval($0) }
            return Quota(name: name, used: min(max(percentage, 0), 100), limit: 100, resetAt: resetAt, kind: kind)
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "Codex 返回中没有可解析的额度窗口")
        }
        return .realtime(subscription: subscription, quotas: quotas)
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
    let rateLimit: RateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
}
