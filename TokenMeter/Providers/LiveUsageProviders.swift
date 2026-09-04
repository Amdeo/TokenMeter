import Foundation
import os

private enum UsageLogger {
    static let logger = Logger(subsystem: "com.tokenmeter.app", category: "usage")
}

struct DeepSeekUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.platform)
        }
        let response: DeepSeekBalanceResponse = try await APIClient.get(
            URL(string: "https://api.deepseek.com/user/balance")!,
            platform: subscription.platform,
            authorization: "Bearer \(key)"
        )
        let balanceInfos = response.balanceInfos ?? []
        UsageLogger.logger.info("deepseek response fields isAvailablePresent=\(response.isAvailable != nil, privacy: .public) balanceInfoCount=\(balanceInfos.count, privacy: .public)")
        for balance in balanceInfos {
            let total = balance.totalBalance?.value
            UsageLogger.logger.info("deepseek balance diagnostics currencyPresent=\(balance.currencyPresent, privacy: .public) totalBalancePresent=\(balance.totalBalanceType != .missing, privacy: .public) totalBalanceType=\(balance.totalBalanceType.rawValue, privacy: .public) parsedFinite=\(total?.isFinite == true, privacy: .public) parsedNegative=\(total.map { $0 < 0 } ?? false, privacy: .public) parsedZero=\(total == 0, privacy: .public)")
        }
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
        UsageLogger.logger.info("deepseek balances validated validBalanceCount=\(validBalances.count, privacy: .public)")
        guard !validBalances.isEmpty else {
            UsageLogger.logger.info("deepseek snapshot generated=false")
            throw UsageProviderError.invalidResponse(subscription.platform, "DeepSeek 返回中缺少可解析的余额条目")
        }
        let selectedBalance = validBalances.first { $0.currency.uppercased() == "USD" }
            ?? validBalances[0]
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额",
                used: 0,
                limit: selectedBalance.total,
                resetAt: nil,
                unit: .currency(code: selectedBalance.currency, scale: 1),
                kind: .balance
            )
        ])
        UsageLogger.logger.info("deepseek selectedBalancePresent=true snapshotGenerated=true")
        return snapshot
    }
}

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
        switch subscription.authMethod {
        case .manualAPIKey:
            guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
                throw UsageProviderError.notConfigured(subscription.platform)
            }
            do {
                return try await fetchCodingUsage(authorization: "Bearer \(key)")
            } catch UsageProviderError.httpStatus(let status) where [401, 403, 404].contains(status) {
                return try await fetchBalance(key: key)
            }
        case .kimiOAuth:
            guard let credential = credentials.oauthCredential(for: subscription.id) else {
                throw UsageProviderError.notConfigured(subscription.platform)
            }
            let activeCredential: OAuthCredential
            let didRefresh: Bool
            if credentials.isExpiringSoon(credential) {
                guard !credential.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw UsageProviderError.authenticationRequired(subscription.platform, "Kimi Code OAuth 凭证已失效，请重新授权")
                }
                do {
                    activeCredential = try await KimiOAuthService().refresh(credential)
                    try credentials.save(oauthCredential: activeCredential, for: subscription.id)
                    didRefresh = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw UsageProviderError.authenticationRequired(subscription.platform, "Kimi Code OAuth 凭证已失效，请重新授权")
                }
            } else {
                activeCredential = credential
                didRefresh = false
            }
            return try await fetchOAuthUsage(credential: activeCredential, didRefresh: didRefresh)
        case .kimiBrowserSession:
            guard let credential = credentials.browserCredential(for: subscription.id) else {
                throw UsageProviderError.notConfigured(subscription.platform)
            }
            guard credential.expiresAt > .now else {
                throw UsageProviderError.authenticationRequired(subscription.platform, "Kimi 网页登录态已过期，请从 Chrome 重新导入")
            }
            do {
                return try await fetchBrowserUsage(credential: credential)
            } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
                throw UsageProviderError.authenticationRequired(subscription.platform, "Kimi 网页登录态已过期，请从 Chrome 重新导入")
            }
        }
    }

    private func fetchOAuthUsage(credential: OAuthCredential, didRefresh: Bool) async throws -> UsageSnapshot {
        do {
            return try await fetchCodingUsage(authorization: "\(credential.tokenType) \(credential.accessToken)")
        } catch UsageProviderError.httpStatus(let status) where [401, 403].contains(status) {
            guard !didRefresh, !credential.refreshToken.isEmpty else {
                throw UsageProviderError.authenticationRequired(subscription.platform, "Kimi Code OAuth 凭证已失效，请重新授权")
            }
            do {
                let refreshed = try await KimiOAuthService().refresh(credential)
                try credentials.save(oauthCredential: refreshed, for: subscription.id)
                return try await fetchOAuthUsage(credential: refreshed, didRefresh: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw UsageProviderError.authenticationRequired(subscription.platform, "Kimi Code OAuth 凭证已失效，请重新授权")
            }
        }
    }

    private func fetchCodingUsage(authorization: String) async throws -> UsageSnapshot {
        let response: KimiUsagesResponse = try await APIClient.get(
            URL(string: "https://api.kimi.com/coding/v1/usages")!,
            platform: subscription.platform,
            authorization: authorization,
            headers: Self.commonHeaders
        )
        return try Self.parseCodingUsage(response, subscription: subscription)
    }

    private func fetchBrowserUsage(credential: KimiBrowserCredential) async throws -> UsageSnapshot {
        let authorization = "\(credential.tokenType) \(credential.accessToken)"
        let response: KimiSubscriptionStatsResponse = try await APIClient.post(
            URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!,
            platform: subscription.platform,
            authorization: authorization,
            headers: Self.browserHeaders
        )
        var fiveHourQuota: Quota?
        do {
            let codingResponse: KimiUsagesResponse = try await APIClient.get(
                URL(string: "https://api.kimi.com/coding/v1/usages")!,
                platform: subscription.platform,
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
            platform: subscription.platform,
            authorization: "Bearer \(key)"
        )
        let balances = [
            ("可用余额", response.data.availableBalance),
            ("代金券余额", response.data.voucherBalance),
            ("现金余额", response.data.cashBalance)
        ]
        guard balances.contains(where: { $0.1.value != nil }) else {
            throw UsageProviderError.invalidResponse(subscription.platform, "Kimi 返回中缺少余额字段")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: balances.compactMap { name, amount in
            guard let value = amount.value, value >= 0 else { return nil }
            return Quota(name: name, used: 0, limit: value, resetAt: nil, kind: .balance)
        })
    }

    static func parseCodingUsage(_ response: KimiUsagesResponse, subscription: Subscription) throws -> UsageSnapshot {
        let limits = response.limits ?? []
        UsageLogger.logger.info("kimi coding response fields usagePresent=\(response.usage != nil, privacy: .public) limitsPresent=\(response.limits != nil, privacy: .public) limitsCount=\(limits.count, privacy: .public) boosterWalletPresent=\(response.boosterWallet != nil, privacy: .public)")

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

        let monthlyQuota = response.totalQuota.flatMap { detail -> Quota? in
            guard let values = quotaValues(from: detail) else {
                return nil
            }
            return Quota(
                name: "月度额度",
                used: values.used,
                limit: values.limit,
                resetAt: date(from: detail.resetTime),
                kind: .monthly
            )
        }

        var quotas = deduplicatedSemanticQuotas(windowQuotas)
        quotas.removeAll { $0.kind == .weekly || $0.kind == .monthly }
        if let weeklyUsage {
            quotas.append(weeklyUsage)
        }
        if let monthlyQuota {
            quotas.append(monthlyQuota)
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
        UsageLogger.logger.info("kimi coding quotas parsed usageParsed=\(weeklyUsage != nil, privacy: .public) windowParsedCount=\(windowQuotas.count, privacy: .public) fiveHourParsed=\(windowQuotas.contains { $0.kind == .fiveHour }, privacy: .public) totalQuotaPresent=\(response.totalQuota != nil, privacy: .public) monthlyQuotaParsed=\(monthlyQuota != nil, privacy: .public) boosterBalanceParsed=\(boosterQuota != nil, privacy: .public) monthlyChargeParsed=\(monthlyChargeQuota != nil, privacy: .public) quotaCount=\(quotas.count, privacy: .public)")

        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.platform, "Kimi For Coding 返回中没有额度数据")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: quotas)
    }

    static func parseSubscriptionStats(
        _ response: KimiSubscriptionStatsResponse,
        subscription: Subscription,
        fiveHourQuota: Quota? = nil
    ) throws -> UsageSnapshot {
        var quotas: [Quota] = []
        if let ratio = normalizedRatio(response.ratelimitCode7d?.ratio?.value) {
            quotas.append(Quota(name: "每周额度", used: ratio, limit: 1, resetAt: date(from: response.ratelimitCode7d?.resetTime), kind: .weekly))
        }
        if let fiveHourQuota {
            quotas.append(fiveHourQuota)
        } else if response.ratelimitCode5h?.enabled == true {
            quotas.append(Quota(name: "5 小时额度", used: 0, limit: 1, resetAt: date(from: response.ratelimitCode5h?.resetTime), kind: .fiveHour))
        }
        let overallUsageRatio = normalizedRatio(response.subscriptionBalance?.amountUsedRatio?.value)
        guard !quotas.isEmpty || overallUsageRatio != nil else {
            throw UsageProviderError.invalidResponse(subscription.platform, "Kimi 网页订阅接口返回中没有可用数据")
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
        case .monthly: return 2
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

struct ZhipuUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.platform)
        }
        // 大陆站 biz/monitor 网关只认裸 API key（无 Bearer 前缀）
        let root: JSONValue = try await APIClient.get(
            URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!,
            platform: subscription.platform,
            authorization: key
        )
        if let code = root.number(for: ["code"]), code != 200 {
            let message = root.string(for: ["message"]) ?? root.string(for: ["msg"]) ?? "未知错误"
            throw UsageProviderError.invalidResponse(subscription.platform, "接口返回错误（code \(Int(code))：\(message)）")
        }
        let data = root.value(for: ["data"])
        let limits = data?.arrayValue ?? data?.value(for: ["limits"])?.arrayValue ?? []
        var quotas: [Quota] = []
        for item in limits {
            let type = item.string(for: ["type"]) ?? item.string(for: ["name"]) ?? ""
            guard type == "TOKENS_LIMIT" else { continue }
            let name = Self.windowName(unit: item.number(for: ["unit"]), number: item.number(for: ["number"]))
            let resetAt = item.number(for: ["nextResetTime"]).map {
                Date(timeIntervalSince1970: $0 > 100_000_000_000 ? $0 / 1000 : $0)
            }
            if let used = item.number(for: ["currentValue"]),
               let limit = item.number(for: ["usage"]), limit > 0 {
                quotas.append(Quota(name: name, used: used, limit: limit, resetAt: resetAt))
            } else if let percentage = item.number(for: ["percentage"]), (0...100).contains(percentage) {
                quotas.append(Quota(name: name, used: percentage, limit: 100, resetAt: resetAt))
            }
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.platform, "响应中没有 GLM Coding Plan 订阅额度窗口")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: quotas)
    }

    private static func windowName(unit: Double?, number: Double?) -> String {
        guard let number else { return "限额窗口" }
        let value = Int(number)
        switch unit.map({ Int($0) }) {
        case 3: return "\(value) 小时窗口"
        case 6: return value == 7 ? "每周窗口" : "\(value) 天窗口"
        default: return "限额窗口"
        }
    }
}

struct OpenCodeGoUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.platform)
        }
        let response: JSONValue = try await APIClient.get(
            URL(string: "https://opencode.ai/zen/go/v1/usage")!,
            platform: subscription.platform,
            authorization: "Bearer \(key)"
        )
        let windows = [
            ("5 小时窗口", ["rolling", "5h", "5_hour", "five_hour", "five_hours", "fivehour"]),
            ("每周窗口", ["weekly", "week"]),
            ("每月窗口", ["monthly", "month"])
        ].compactMap { name, aliases -> Quota? in
            guard let value = response.findObject(for: aliases) else { return nil }
            return try? Quota.fromOpenCodeWindow(name: name, object: value)
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.platform, "OpenCode Go 返回中未找到可可靠解析的用量窗口")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: windows)
    }
}

struct MiniMaxUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.platform)
        }
        let response: MiniMaxRemainsResponse = try await APIClient.get(
            URL(string: "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains")!,
            platform: subscription.platform,
            authorization: "Bearer \(key)"
        )
        guard response.baseResp.statusCode == 0 else {
            throw UsageProviderError.invalidResponse(subscription.platform, response.baseResp.statusMsg ?? "接口返回错误")
        }
        let quotas = response.modelRemains.compactMap { model -> Quota? in
            guard let total = model.currentIntervalTotalCount?.value,
                  let remaining = model.currentIntervalUsageCount?.value,
                  total > 0 else { return nil }
            let resetAt = model.endTime?.value.map { Date(timeIntervalSince1970: $0 / 1000) }
            return Quota(name: model.modelName ?? "Coding Plan 额度", used: max(0, total - remaining), limit: total, resetAt: resetAt)
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.platform, "MiniMax Coding Plan 返回中没有套餐额度")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: quotas)
    }
}

enum LiveUsageProviders {
    static func provider(for subscription: Subscription) -> any UsageProvider {
        switch subscription.platform {
        case .deepSeek: DeepSeekUsageProvider(subscription: subscription)
        case .kimi: KimiUsageProvider(subscription: subscription)
        case .openCodeGo: OpenCodeGoUsageProvider(subscription: subscription)
        case .zhipu: ZhipuUsageProvider(subscription: subscription)
        case .miniMax: MiniMaxUsageProvider(subscription: subscription)
        }
    }
}

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
    let currencyPresent: Bool
    let totalBalanceType: JSONFieldType

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currencyPresent = container.contains(.currency)
        totalBalanceType = try container.decodeFieldType(forKey: .totalBalance)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        totalBalance = try container.decodeIfPresent(FlexibleNumber.self, forKey: .totalBalance)
        grantedBalance = try container.decodeIfPresent(FlexibleNumber.self, forKey: .grantedBalance)
        toppedUpBalance = try container.decodeIfPresent(FlexibleNumber.self, forKey: .toppedUpBalance)
    }
}

private enum JSONFieldType: String, Sendable {
    case string
    case number
    case null
    case missing
    case other
}

private extension KeyedDecodingContainer where Key: CodingKey {
    func decodeFieldType(forKey key: Key) throws -> JSONFieldType {
        guard contains(key) else { return .missing }
        let value = try superDecoder(forKey: key)
        let container = try value.singleValueContainer()
        if container.decodeNil() { return .null }
        if (try? container.decode(String.self)) != nil { return .string }
        if (try? container.decode(Double.self)) != nil { return .number }
        return .other
    }
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
    let totalQuota: QuotaDetail?
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

private struct MiniMaxRemainsResponse: Decodable {
    struct ModelRemain: Decodable {
        let modelName: String?
        let endTime: FlexibleNumber?
        let currentIntervalTotalCount: FlexibleNumber?
        let currentIntervalUsageCount: FlexibleNumber?

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case endTime = "end_time"
            case currentIntervalTotalCount = "current_interval_total_count"
            case currentIntervalUsageCount = "current_interval_usage_count"
        }
    }

    struct BaseResp: Decodable {
        let statusCode: Int
        let statusMsg: String?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMsg = "status_msg"
        }
    }

    let modelRemains: [ModelRemain]
    let baseResp: BaseResp

    enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }
}

struct FlexibleNumber: Decodable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
    }
}

private enum JSONValue: Decodable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let boolean = try? container.decode(Bool.self) {
            self = .boolean(boolean)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    func value(for aliases: [String]) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        let names = Set(aliases.map(Self.normalize))
        for (key, value) in object where names.contains(Self.normalize(key)) { return value }
        return nil
    }

    func findObject(for aliases: [String]) -> JSONValue? {
        guard case .object(let object) = self else {
            if case .array(let values) = self {
                return values.lazy.compactMap { $0.findObject(for: aliases) }.first
            }
            return nil
        }
        let normalizedAliases = Set(aliases.map(Self.normalize))
        if let match = object.first(where: { normalizedAliases.contains(Self.normalize($0.key)) }),
           case .object = match.value {
            return match.value
        }
        return object.values.lazy.compactMap { $0.findObject(for: aliases) }.first
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func number(for aliases: [String]) -> Double? {
        guard case .object(let object) = self else { return nil }
        let names = Set(aliases.map(Self.normalize))
        for (key, value) in object where names.contains(Self.normalize(key)) {
            switch value {
            case .number(let number): return number
            case .string(let string): return Double(string)
            default: continue
            }
        }
        return nil
    }

    func string(for aliases: [String]) -> String? {
        guard case .object(let object) = self else { return nil }
        let names = Set(aliases.map(Self.normalize))
        for (key, value) in object where names.contains(Self.normalize(key)) {
            if case .string(let string) = value { return string }
        }
        return nil
    }
}

private extension Quota {
    static func fromOpenCodeWindow(name: String, object: JSONValue) throws -> Quota {
        if let percent = object.number(for: ["percent", "percentage", "usage_percent", "usagePercentage"]),
           percent >= 0, percent <= 100 {
            return Quota(name: name, used: percent, limit: 100, resetAt: object.resetDate)
        }
        guard let used = object.number(for: ["used", "usage", "consumed", "used_tokens"]),
              let limit = object.number(for: ["limit", "max", "maximum", "total", "allowance"]),
              used >= 0, limit > 0 else {
            throw UsageProviderError.invalidResponse(.openCodeGo, "OpenCode Go 用量窗口缺少 percent 或 used/limit")
        }
        return Quota(name: name, used: used, limit: limit, resetAt: object.resetDate)
    }
}

private extension JSONValue {
    var resetDate: Date? {
        if let string = string(for: ["reset_at", "resetAt", "resets_at", "resetsAt", "reset", "reset_time"]) {
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            if let timestamp = Double(string) { return Self.date(from: timestamp) }
        }
        if let timestamp = number(for: ["reset_at", "resetAt", "resets_at", "resetsAt", "reset", "reset_time"]) {
            return Self.date(from: timestamp)
        }
        return nil
    }

    static func date(from timestamp: Double) -> Date {
        Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
    }
}

private enum APIClient {
    static func get<Response: Decodable>(_ url: URL, platform: Platform, authorization: String, headers: [String: String] = [:]) async throws -> Response {
        UsageLogger.logger.debug("request started platform=\(platform.rawValue, privacy: .public) type=\(String(describing: Response.self), privacy: .public)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            UsageLogger.logger.error("response invalid platform=\(platform.rawValue, privacy: .public) byteCount=\(data.count, privacy: .public) type=\(String(describing: Response.self), privacy: .public) errorClass=nonHTTPResponse")
            throw UsageProviderError.requestFailed(platform, "服务器返回了无效响应")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            UsageLogger.logger.error("response rejected platform=\(platform.rawValue, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) byteCount=\(data.count, privacy: .public) type=\(String(describing: Response.self), privacy: .public) errorClass=httpStatus")
            switch (platform, httpResponse.statusCode) {
            case (.deepSeek, 401), (.deepSeek, 403):
                throw UsageProviderError.authenticationRequired(platform, "API Key 无效或无权访问余额接口")
            case (.deepSeek, 402):
                throw UsageProviderError.requestFailed(platform, "账户余额不足")
            case (.deepSeek, 429):
                throw UsageProviderError.requestFailed(platform, "请求过于频繁，请稍后重试")
            default:
                throw UsageProviderError.httpStatus(httpResponse.statusCode)
            }
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            UsageLogger.logger.info("response decoded platform=\(platform.rawValue, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) byteCount=\(data.count, privacy: .public) type=\(String(describing: Response.self), privacy: .public)")
            return decoded
        } catch {
            UsageLogger.logger.error("response decode failed platform=\(platform.rawValue, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) byteCount=\(data.count, privacy: .public) type=\(String(describing: Response.self), privacy: .public) errorClass=decodeFailure")
            throw UsageProviderError.invalidJSON
        }
    }

    static func post<Response: Decodable>(_ url: URL, platform: Platform, authorization: String, headers: [String: String] = [:], body: Data = Data("{}".utf8)) async throws -> Response {
        UsageLogger.logger.debug("request started platform=\(platform.rawValue, privacy: .public) type=\(String(describing: Response.self), privacy: .public)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageProviderError.requestFailed(platform, "服务器返回了无效响应")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UsageProviderError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageProviderError.invalidJSON
        }
    }
}
