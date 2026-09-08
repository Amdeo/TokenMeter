import Foundation

// MARK: - 定义

@MainActor
struct APIKeyFunProviderDefinition: ProviderDefinition {
    let id = ProviderID.apikeyFun

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "APIKEY.FUN",
            iconResourceName: "icon-apikeyfun",
            fallbackSystemImage: "key.fill",
            tintRGB: 0x6E6CF0,
            capabilityDescription: "支持账户余额，可通过网页登录态获取。",
            authPageURL: URL(string: "https://apikey.fun/login"),
            authenticationSummary: "网页登录态 · 支持账户余额"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(
            id: .apikeyFunBrowserSession,
            flowID: .browserSession,
            title: "网页登录态",
            systemImage: "globe",
            tintRGB: 0x6E6CF0,
            detail: "登录 APIKEY.FUN 账号（内置）"
        )]
    }

    let cardRenderer: any ProviderCardRenderer = BalanceCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        APIKeyFunUsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(name: "可用余额", used: 0, limit: 18.14, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)
        ])
    }
}

// MARK: - 用量提供者

struct APIKeyFunUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
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
                credential = try await APIKeyFunSessionRefresher.refresh(stored)
                try credentials.save(browserCredential: credential, for: subscription.id)
                didRefresh = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "APIKEY.FUN 网页登录态已过期，请在订阅设置中重新登录")
            }
        }
        do {
            return try await fetchBalance(credential: credential)
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            guard !didRefresh else {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "APIKEY.FUN 网页登录态已过期，请在订阅设置中重新登录")
            }
            do {
                let refreshed = try await APIKeyFunSessionRefresher.refresh(credential)
                try credentials.save(browserCredential: refreshed, for: subscription.id)
                return try await fetchBalance(credential: refreshed)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.providerID, "APIKEY.FUN 网页登录态已过期，请在订阅设置中重新登录")
            }
        }
    }

    private func fetchBalance(credential: KimiBrowserCredential) async throws -> UsageSnapshot {
        let response: MeResponse = try await APIClient.get(
            APIKeyFunSessionRefresher.apiBase.appendingPathComponent("/auth/me"),
            providerID: subscription.providerID,
            authorization: "\(credential.tokenType) \(credential.accessToken)"
        )
        guard response.code == 0, let data = response.data else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "APIKEY.FUN 返回中缺少余额字段")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额",
                used: 0,
                limit: data.balance,
                resetAt: nil,
                unit: .currency(code: "USD", scale: 1),
                kind: .balance
            )
        ])
    }
}

// MARK: - 响应类型

private struct MeResponse: Decodable {
    struct Data: Decodable {
        let balance: Double
    }

    let code: Int
    let data: Data?
}
