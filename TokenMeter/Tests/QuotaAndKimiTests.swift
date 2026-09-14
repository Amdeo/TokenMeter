import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import TokenMeter

@MainActor
struct QuotaAndKimiTests {
    @Test
    func subscriptionDecodingDefaultsCardStyleToStandard() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "providerID": "deepSeek",
            "name": "DeepSeek",
            "authMethodID": "apiKey",
            "createdAt": 0.0,
            "isEnabled": true
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let subscription = try decoder.decode(Subscription.self, from: data)

        #expect(subscription.cardStyle == .standard)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let roundTripped = try decoder.decode(
            Subscription.self,
            from: encoder.encode(Subscription(id: id, providerID: .deepSeek, name: "DeepSeek", cardStyle: .compact))
        )
        #expect(roundTripped.cardStyle == .compact)
    }

    @Test
    func credentialStoreSavesReadsAndRemovesAPIKey() throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: fileURL)
        let subscriptionID = UUID()

        try store.save(apiKey: "  test-key  ", for: subscriptionID)

        #expect(store.apiKey(for: subscriptionID) == "test-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.remove(for: subscriptionID)
        #expect(store.apiKey(for: subscriptionID) == nil)
    }

    @Test
    func credentialStoreSavesReadsAndRemovesOAuthCredential() throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: fileURL)
        let subscriptionID = UUID()
        let credential = OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            tokenType: "Bearer"
        )

        try store.save(oauthCredential: credential, for: subscriptionID)

        #expect(store.oauthCredential(for: subscriptionID) == credential)
        try store.remove(for: subscriptionID)
        #expect(store.oauthCredential(for: subscriptionID) == nil)
    }

    @Test
    func credentialStoreSavesReadsAndRemovesBrowserCredential() throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: fileURL)
        let subscriptionID = UUID()
        let credential = BrowserTokenCredential(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            tokenType: "Bearer"
        )

        try store.save(browserCredential: credential, for: subscriptionID)

        #expect(store.browserCredential(for: subscriptionID) == credential)
        try store.remove(for: subscriptionID)
        #expect(store.browserCredential(for: subscriptionID) == nil)
    }

    @Test(arguments: [Data(), Data("not-json".utf8)])
    func credentialStoreDoesNotOverwriteEmptyOrCorruptFile(_ original: Data) throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: fileURL)
        let store = CredentialStore(fileURL: fileURL)

        var didThrow = false
        do {
            try store.save(apiKey: "replacement", for: UUID())
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: fileURL) == original)
    }

    @Test
    func deepSeekBalanceQuotaKeepsCurrencyUnit() {
        let quota = Quota(name: "可用余额", used: 0, limit: 12.34, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)

        #expect(quota.kind == .balance)
        #expect(quota.unit == .currency(code: "USD", scale: 1))
        #expect(quota.remainingText == "USD 12.34")
    }

    @Test
    func deepSeekBalanceQuotaPreservesNegativeValue() {
        let quota = Quota(name: "可用余额", used: 0, limit: -3.50, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)

        #expect(quota.remainingText == "USD -3.50")
    }

    @Test
    func oldQuotaDataDefaultsToGenericKind() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"旧额度","used":1,"limit":2,"resetAt":null}
        """.utf8)

        let quota = try JSONDecoder().decode(Quota.self, from: data)
        #expect(quota.kind == .generic)
    }

    @Test
    func oldUsageSnapshotDataDefaultsOverallUsageRatioToNil() throws {
        let data = Data("""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "subscriptionID":"00000000-0000-0000-0000-000000000002",
          "platform":"Kimi",
          "quotas":[],
          "updatedAt":0,
          "isDemo":false,
          "errorMessage":null,
          "state":"realtime"
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)

        #expect(snapshot.overallUsageRatio == nil)
    }

    @Test
    func kimiCodingUsageMapsCoreWindowsAndDeduplicatesSemanticKinds() throws {
        let data = Data("""
        {
          "usage": {"used": 100, "limit": 1000, "resetTime": "2030-01-08T00:00:00Z"},
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"used": 0, "limit": 100, "resetTime": "2030-01-01T00:00:00Z"}},
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"used": 60, "limit": 100, "resetTime": "2030-01-01T00:00:00Z"}},
            {"window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}, "detail": {"used": 200, "limit": 1000, "resetTime": "2030-01-08T00:00:00Z"}}
          ],
          "totalQuota": {"limit": 5000, "remaining": 4000, "resetTime": "2030-02-01T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)

        let snapshot = try KimiUsageProvider.parseCodingUsage(response, subscription: subscription)
        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.quotas[0].fraction == 0)
        #expect(snapshot.quotas[0].usedText == "0")
    }

    @Test
    func kimiDirectLimitWindowIsParsedAsFiveHourQuota() throws {
        let data = Data("""
        {
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "limit": "1000", "remaining": "750"}
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)

        let snapshot = try KimiUsageProvider.parseCodingUsage(response, subscription: subscription)
        let fiveHour = try #require(snapshot.quotas.first { $0.kind == .fiveHour })

        #expect(fiveHour.used == 250)
        #expect(fiveHour.limit == 1000)
    }

    @Test
    func kimiFiveHourWindowUsesRemainingWhenUsedIsOmitted() throws {
        let data = Data("""
        {
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": 1000, "remaining": 750}}
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)

        let snapshot = try KimiUsageProvider.parseCodingUsage(response, subscription: subscription)
        let fiveHour = try #require(snapshot.quotas.first { $0.kind == .fiveHour })

        #expect(fiveHour.used == 250)
        #expect(fiveHour.limit == 1000)
    }

    @Test
    func kimiBalanceSnapshotIsIdentifiableAsFallbackMode() {
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "可用余额", used: 0, limit: 8, resetAt: nil, kind: .balance)
        ])
        let coreKinds: Set<Quota.Kind> = [.fiveHour, .weekly]

        #expect(!snapshot.quotas.contains { coreKinds.contains($0.kind) })
        #expect(snapshot.quotas.contains { $0.kind == .balance })
    }

    @Test
    func kimiSubscriptionStatsMapsTotalAndWeeklyUsageAndTreatsEnabledMissingFiveHourRatioAsZero() throws {
        let data = Data("""
        {
          "ratelimitCode5h": {"enabled": true, "resetTime": "2030-01-01T00:00:00Z"},
          "ratelimitCode7d": {"ratio": 0.558, "resetTime": "2030-01-07T00:00:00Z"},
          "subscriptionBalance": {"amountUsedRatio": 0.872, "expireTime": "2030-02-01T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.overallUsageRatio == 0.872)
        #expect(snapshot.quotas.map(\.kind) == [.monthly, .fiveHour, .weekly])
        #expect(snapshot.quotas[0].fraction == 0.872)
        #expect(snapshot.quotas[0].resetAt != nil)
        #expect(snapshot.quotas[1].fraction == 0)
        #expect(snapshot.quotas[1].usedText == "0")
        #expect(snapshot.quotas[2].fraction == 0.558)
    }

    @Test
    func kimiSubscriptionStatsTreatsWindowWithoutZeroValueFieldsAsFiveHourQuota() throws {
        let data = Data("""
        {
          "ratelimitCode5h": {"resetTime": "2030-01-01T00:00:00Z"},
          "ratelimitCode7d": {"ratio": 0.558, "resetTime": "2030-01-07T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.quotas[0].fraction == 0)
        #expect(snapshot.quotas[0].resetAt != nil)
    }

    @Test
    func kimiSubscriptionStatsDoesNotInventMissingFiveHourWindow() throws {
        let data = Data("""
        {
          "ratelimitCode7d": {"ratio": 0.558, "resetTime": "2030-01-07T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.quotas.map(\.kind) == [.weekly])
    }

    @Test
    func kimiSubscriptionStatsSkipsExplicitlyDisabledFiveHourWindow() throws {
        let data = Data("""
        {
          "ratelimitCode5h": {"enabled": false, "resetTime": "2030-01-01T00:00:00Z"},
          "ratelimitCode7d": {"ratio": 0.558, "resetTime": "2030-01-07T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.quotas.map(\.kind) == [.weekly])
    }

    @Test
    func kimiSubscriptionStatsUsesFiveHourRatioWhenPresent() throws {
        let data = Data("""
        {
          "ratelimitCode5h": {"ratio": 0.0797, "enabled": true, "resetTime": "2030-01-01T00:00:00Z"},
          "ratelimitCode7d": {"ratio": 0.558, "resetTime": "2030-01-07T00:00:00Z"},
          "subscriptionBalance": {"amountUsedRatio": 0.872, "expireTime": "2030-02-01T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.quotas.map(\.kind) == [.monthly, .fiveHour, .weekly])
        #expect(snapshot.quotas[1].used == 0.0797)
        #expect(snapshot.quotas[1].fraction == 0.0797)
    }

    @Test
    func kimiSubscriptionStatsTreatsEnabledMissingWeeklyRatioAsZero() throws {
        // 服务器在周额度恰好为 0 时会省略 ratio 字段（proto3 JSON 零值省略），
        // 窗口仍启用时应按 0% 展示，而不是丢失每周额度行。
        let data = Data("""
        {
          "ratelimitCode5h": {"enabled": true, "resetTime": "2030-01-01T00:00:00Z"},
          "ratelimitCode7d": {"enabled": true, "resetTime": "2030-01-07T00:00:00Z"},
          "subscriptionBalance": {"amountUsedRatio": 0.5, "expireTime": "2030-02-01T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.quotas.map(\.kind) == [.monthly, .fiveHour, .weekly])
        #expect(snapshot.quotas[2].fraction == 0)
        #expect(snapshot.quotas[2].resetAt != nil)
    }

    @Test
    func kimiSubscriptionStatsSkipsInvalidFiveHourRatio() throws {
        let data = Data("""
        {
          "ratelimitCode5h": {"ratio": -1, "enabled": true},
          "ratelimitCode7d": {"ratio": 0.558, "resetTime": "2030-01-07T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.quotas.map(\.kind) == [.weekly])
    }

    @Test
    func kimiSubscriptionStatsMonthlyQuotaCarriesResetTimeFromExpireTime() throws {
        // 月额度行排在最前，重置时间取 subscriptionBalance.expireTime。
        let data = Data("""
        {
          "ratelimitCode7d": {"ratio": 0.0175, "resetTime": "2030-01-07T00:00:00Z"},
          "subscriptionBalance": {"amountUsedRatio": 0.9747, "expireTime": "2030-01-20T01:28:01.324990Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)
        let monthly = try #require(snapshot.quotas.first { $0.kind == .monthly })

        #expect(monthly.name == "月额度")
        #expect(monthly.fraction == 0.9747)
        #expect(monthly.resetAt != nil)
        #expect(snapshot.quotas.first?.kind == .monthly)
    }

    @Test
    func kimiCardStatusCountsMonthlyQuota() {
        // 月额度见底时状态点必须是 warning，不能被 5 小时/每周的低占用盖成 normal。
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "月额度", used: 0.975, limit: 1, resetAt: nil, kind: .monthly),
            Quota(name: "5 小时额度", used: 0.01, limit: 1, resetAt: nil, kind: .fiveHour),
            Quota(name: "每周额度", used: 0.02, limit: 1, resetAt: nil, kind: .weekly)
        ])

        #expect(KimiCardRenderer().status(subscription: subscription, snapshot: snapshot) == .warning)
    }

    private func temporaryCredentialFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }
}

extension QuotaAndKimiTests {
    @Test
    func credentialSavesKeepOnlyTheCurrentAuthenticationMethod() throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: fileURL)
        let id = UUID()
        let oauth = OAuthCredential(accessToken: "oauth", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")
        let browser = BrowserTokenCredential(accessToken: "browser", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")

        try store.save(apiKey: "manual", for: id)
        #expect(store.apiKey(for: id) == "manual")
        #expect(store.oauthCredential(for: id) == nil)
        #expect(store.browserCredential(for: id) == nil)

        try store.save(oauthCredential: oauth, for: id)
        #expect(store.apiKey(for: id) == nil)
        #expect(store.oauthCredential(for: id) == oauth)
        #expect(store.browserCredential(for: id) == nil)

        try store.save(browserCredential: browser, for: id)
        #expect(store.apiKey(for: id) == nil)
        #expect(store.oauthCredential(for: id) == nil)
        #expect(store.browserCredential(for: id) == browser)
    }
}

extension QuotaAndKimiTests {
    @Test
    func subscriptionCardRatioThresholds() {
        #expect(SubscriptionCardPresentation.ratioStatus(for: 0.79) == .normal)
        #expect(SubscriptionCardPresentation.ratioStatus(for: 0.8) == .warning)
        #expect(SubscriptionCardPresentation.ratioStatus(for: 1.0) == .exhausted)
    }

    @Test
    func subscriptionCardResetHintRoundsToLocalizedUnits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(SubscriptionCardPresentation.resetHintText(for: now.addingTimeInterval(90), now: now) == "1 分钟后刷新额度")
        #expect(SubscriptionCardPresentation.resetHintText(for: now.addingTimeInterval(3_600), now: now) == "1 小时后刷新额度")
        #expect(SubscriptionCardPresentation.resetHintText(for: now.addingTimeInterval(2 * 86_400), now: now) == "2 天后刷新额度")
        #expect(SubscriptionCardPresentation.resetHintText(for: now.addingTimeInterval(-10), now: now) == "即将刷新额度")
    }

    @Test
    func subscriptionCardAnchorIsNilForDeepSeekBalance() {
        // DeepSeek 头部不再显示「可用余额」锚点，余额改由正文单行展示。
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "API 余额", used: 0, limit: 18.42, resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance)
        ])

        #expect(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot) == nil)
    }

    @Test
    func subscriptionCardAnchorUsesKimiTotalRatio() throws {
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiDeviceOAuth)
        let snapshot = UsageSnapshot.realtime(
            subscription: subscription,
            quotas: [
                Quota(name: "5 小时额度", used: 41, limit: 100, resetAt: nil, kind: .fiveHour),
                Quota(name: "每周额度", used: 30, limit: 100, resetAt: nil, kind: .weekly)
            ],
            overallUsageRatio: 0.41
        )

        let anchor = try #require(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot))

        #expect(anchor.value == 0.41.formatted(.percent.precision(.fractionLength(1))))
        #expect(anchor.accessibilityLabel == "总使用量 \(anchor.value)")
        // 未配置：overall 锚点回退到 ratioStatus 对应的状态色（normal → TM.ok），而非内置默认 indigo。
        #expect(!SubscriptionQuotaColors.hasOverallConfiguration(subscription.quotaColors))
        #expect(anchor.colorRGB == SubscriptionCardPresentation.ratioStatus(for: 0.41).tint.tokenMeterRGB)
        #expect(anchor.colorRGB != SubscriptionQuotaColors.overallDefault.tokenMeterRGB)
    }

    @Test
    func subscriptionCardAnchorFallsBackToKimiCoreWindow() throws {
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiDeviceOAuth)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时额度", used: 55, limit: 100, resetAt: nil, kind: .fiveHour)
        ])

        let anchor = try #require(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot))

        #expect(anchor.value == 0.55.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test
    func subscriptionCardAnchorIsNilForBalanceOnlyKimi() {
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "可用余额", used: 0, limit: 8, resetAt: nil, kind: .balance)
        ])

        #expect(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot) == nil)
    }

    @Test
    func subscriptionCardAnchorUsesFirstQuotaForGenericPlatform() throws {
        let subscription = Subscription(providerID: .zhipu, name: "智谱 AI", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时额度", used: 60, limit: 100, resetAt: nil, kind: .fiveHour),
            Quota(name: "每周额度", used: 20, limit: 100, resetAt: nil, kind: .weekly)
        ])

        let anchor = try #require(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot))

        #expect(anchor.value == 0.60.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test
    func subscriptionCardAnchorUsesOpenCodeGoMonthlyWindow() throws {
        // OpenCodeGo 头部锚点应优先显示「每月窗口」这一周期值，而非第一个（5 小时）配额。
        let subscription = Subscription(providerID: .openCodeGo, name: "OpenCode Go", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时窗口", used: 82, limit: 100, resetAt: nil, kind: .fiveHour),
            Quota(name: "每周窗口", used: 20, limit: 100, resetAt: nil, kind: .weekly),
            Quota(name: "每月窗口", used: 35, limit: 100, resetAt: nil, kind: .generic)
        ])

        let anchor = try #require(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot))

        #expect(anchor.value == 0.35.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test
    func subscriptionCardAnchorIsNilWithoutQuotaData() {
        let subscription = Subscription(providerID: .zhipu, name: "智谱 AI", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [])

        #expect(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot) == nil)
    }

    @Test
    func subscriptionCardAnchorIsNilWhenDeepSeekBalanceMissing() {
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时额度", used: 1, limit: 100, resetAt: nil, kind: .fiveHour)
        ])

        #expect(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot) == nil)
    }

    @Test(arguments: zip(
        [UsageState.authenticationRequired, .notConfigured, .unsupported, .error],
        ["认证已失效", "需要配置", "暂不支持额度接口", "获取失败"]
    ))
    func subscriptionCardAccessibilityReportsState(_ state: UsageState, _ expected: String) {
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let snapshot = UsageSnapshot(
            subscriptionID: subscription.id,
            providerID: .kimi,
            quotas: [],
            updatedAt: .now,
            errorMessage: nil,
            state: state
        )

        let label = SubscriptionCardPresentation.cardAccessibilityLabel(subscription: subscription, snapshot: snapshot, anchor: nil)

        #expect(label == "编辑 Kimi 的配置，\(expected)")
    }

    @Test
    func subscriptionCardAccessibilityReportsWaitingForFirstRefresh() {
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)

        let label = SubscriptionCardPresentation.cardAccessibilityLabel(subscription: subscription, snapshot: nil, anchor: nil)

        #expect(label == "编辑 DeepSeek 的配置，等待首次刷新…")
    }



    @Test(arguments: zip(
        [UsageState.notConfigured, .unsupported, .authenticationRequired, .error],
        [QuotaStatus.warning, .warning, .warning, .error]
    ))
    func cardIndicatorStatusMapsState(_ state: UsageState, _ expected: QuotaStatus) {
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let snapshot = UsageSnapshot(
            subscriptionID: subscription.id,
            providerID: .kimi,
            quotas: [],
            updatedAt: .now,
            errorMessage: nil,
            state: state
        )

        #expect(SubscriptionCardPresentation.cardIndicatorStatus(snapshot: snapshot, subscription: subscription) == expected)
    }

    @Test
    func cardIndicatorStatusUsesRealtimeWarningQuota() {
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "API 余额", used: 90, limit: 100, resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance)
        ])

        #expect(SubscriptionCardPresentation.cardIndicatorStatus(snapshot: snapshot, subscription: subscription) == .warning)
    }

    @Test
    func generalPlatformRealtimeVisibleStatusIgnoresErrorMessage() {
        let subscription = Subscription(providerID: .zhipu, name: "智谱 AI", authMethodID: .apiKey)
        let snapshot = UsageSnapshot(
            subscriptionID: subscription.id,
            providerID: .zhipu,
            quotas: [Quota(name: "5 小时额度", used: 90, limit: 100, resetAt: nil, kind: .fiveHour)],
            updatedAt: .now,
            errorMessage: "上游附带错误",
            state: .realtime
        )

        #expect(snapshot.visibleStatus(for: subscription) == .warning)
        #expect(SubscriptionCardPresentation.cardIndicatorStatus(snapshot: snapshot, subscription: subscription) == .warning)
    }

}

extension QuotaAndKimiTests {
    @Test
    func oldSubscriptionDataDefaultsQuotaColorsToEmpty() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","platform":"Kimi","name":"Kimi","authMethod":"manualAPIKey","createdAt":0,"isEnabled":true}
        """.utf8)

        let subscription = try JSONDecoder().decode(Subscription.self, from: data)

        #expect(subscription.quotaColors.isEmpty)
    }

    @Test
    func subscriptionCodableRoundTripsQuotaColors() throws {
        var subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        subscription.quotaColors = [
            SubscriptionQuotaColors.overallKey: 0x3366AA,
            SubscriptionQuotaColors.nameKey("每周额度"): 0x11BB22
        ]

        let decoded = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(subscription))

        #expect(decoded.quotaColors == subscription.quotaColors)
    }

    @Test
    func subscriptionQuotaColorNameKeyNormalization() {
        #expect(SubscriptionQuotaColors.nameKey("  5 小时  额度  ") == "name.5 小时 额度")
        #expect(SubscriptionQuotaColors.nameKey("Weekly Quota") == "name.weekly quota")
        #expect(SubscriptionQuotaColors.nameKey("TAB\tX") == "name.tab x")
    }

    @Test
    func subscriptionQuotaColorRGBRoundTrip() {
        let rgb: UInt32 = 0x12ABEF
        #expect(Color(hex: rgb).tokenMeterRGB == rgb)
    }

    @Test
    func subscriptionQuotaColorResolutionPriority() {
        let nameRGB: UInt32 = 0x111111
        let kindRGB: UInt32 = 0x222222
        let genericRGB: UInt32 = 0x333333
        let quota = Quota(name: "5 小时额度", used: 1, limit: 10, resetAt: nil, kind: .fiveHour)
        let colors: [String: UInt32] = [
            SubscriptionQuotaColors.nameKey("5 小时额度"): nameRGB,
            SubscriptionQuotaColors.fiveHourKey: kindRGB,
            SubscriptionQuotaColors.genericKey: genericRGB
        ]

        // 名称专属 > 语义类型 > generic
        #expect(SubscriptionQuotaColors.resolve(colors, quota: quota).tokenMeterRGB == nameRGB)

        // 没有名称专属时退到语义类型
        let withoutName = colors.filter { $0.key != SubscriptionQuotaColors.nameKey("5 小时额度") }
        #expect(SubscriptionQuotaColors.resolve(withoutName, quota: quota).tokenMeterRGB == kindRGB)

        // 只剩 generic 回退
        let genericOnly = [SubscriptionQuotaColors.genericKey: genericRGB]
        #expect(SubscriptionQuotaColors.resolve(genericOnly, quota: quota).tokenMeterRGB == genericRGB)
    }

    @Test
    func subscriptionQuotaColorFallsBackToBuiltInDefault() {
        let quota = Quota(name: "5 小时额度", used: 1, limit: 10, resetAt: nil, kind: .fiveHour)
        #expect(
            SubscriptionQuotaColors.resolve([:], quota: quota).tokenMeterRGB
                == SubscriptionQuotaColors.defaultColor(forKind: .fiveHour).tokenMeterRGB
        )
    }

    @Test
    func subscriptionQuotaColorResolvesOverall() {
        let rgb: UInt32 = 0x224466
        #expect(SubscriptionQuotaColors.resolveOverall([SubscriptionQuotaColors.overallKey: rgb]).tokenMeterRGB == rgb)
        #expect(
            SubscriptionQuotaColors.resolveOverall([:]).tokenMeterRGB
                == SubscriptionQuotaColors.overallDefault.tokenMeterRGB
        )
    }

    @Test
    func subscriptionQuotaColorResolvesOverallWithGenericFallback() {
        let generic: UInt32 = 0x113355
        #expect(SubscriptionQuotaColors.resolveOverall([SubscriptionQuotaColors.genericKey: generic]).tokenMeterRGB == generic)
        #expect(
            SubscriptionQuotaColors.resolveOverall([
                SubscriptionQuotaColors.overallKey: 0x224466,
                SubscriptionQuotaColors.genericKey: generic
            ]).tokenMeterRGB == 0x224466
        )
    }

    @Test
    func subscriptionQuotaColorHasConfigurationDetection() {
        let quota = Quota(name: "5 小时额度", used: 1, limit: 10, resetAt: nil, kind: .fiveHour)
        #expect(!SubscriptionQuotaColors.hasConfiguration([:], name: quota.name, kind: quota.kind))
        #expect(SubscriptionQuotaColors.hasConfiguration([SubscriptionQuotaColors.nameKey(quota.name): 0x111111], name: quota.name, kind: quota.kind))
        #expect(SubscriptionQuotaColors.hasConfiguration([SubscriptionQuotaColors.fiveHourKey: 0x222222], name: quota.name, kind: quota.kind))
        #expect(SubscriptionQuotaColors.hasConfiguration([SubscriptionQuotaColors.genericKey: 0x333333], name: quota.name, kind: quota.kind))

        #expect(!SubscriptionQuotaColors.hasOverallConfiguration([:]))
        #expect(SubscriptionQuotaColors.hasOverallConfiguration([SubscriptionQuotaColors.overallKey: 0x444444]))
        #expect(SubscriptionQuotaColors.hasOverallConfiguration([SubscriptionQuotaColors.genericKey: 0x555555]))
    }

    @Test
    func subscriptionQuotaColorResolutionWeeklyKindAndAlphaIgnored() {
        let weekly: UInt32 = 0x00AA55
        let quota = Quota(name: "每周额度", used: 1, limit: 10, resetAt: nil, kind: .weekly)
        #expect(SubscriptionQuotaColors.resolve([SubscriptionQuotaColors.weeklyKey: weekly], quota: quota).tokenMeterRGB == weekly)

        // 自定义颜色带透明度：tokenMeterRGB 忽略 alpha，只保留 6 位 RGB。
        let withAlpha = Color(red: 0x12 / 255.0, green: 0xAB / 255.0, blue: 0xEF / 255.0, opacity: 0.5)
        #expect(withAlpha.tokenMeterRGB == 0x12ABEF)
    }

    @Test
    func cardAnchorUsesConfiguredColorAndPreservesStatusSemantics() {
        var subscription = Subscription(providerID: .zhipu, name: "智谱", authMethodID: .apiKey)
        let quota = Quota(name: "每月窗口", used: 85, limit: 100, resetAt: nil, kind: .generic)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [quota])

        // 未配置：锚点回退到 status.tint（精确等于 warning 状态色，而非内置默认 teal）。
        let unconfigured = SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot)
        #expect(!SubscriptionQuotaColors.hasConfiguration(subscription.quotaColors, name: quota.name, kind: quota.kind))
        #expect(unconfigured?.colorRGB == QuotaStatus.warning.tint.tokenMeterRGB)
        #expect(unconfigured?.colorRGB != SubscriptionQuotaColors.defaultColor(forKind: .generic).tokenMeterRGB)

        // 配置后：百分比使用解析色。
        let custom: UInt32 = 0x123456
        subscription.quotaColors = [SubscriptionQuotaColors.nameKey(quota.name): custom]
        let configured = SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot)
        #expect(configured?.colorRGB == custom)
    }

    @Test @MainActor
    func editorDraftTracksQuotaColorDirtyState() {
        var subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        subscription.quotaColors = [SubscriptionQuotaColors.overallKey: 0x112233]
        let draft = SubscriptionEditorDraft(subscription: subscription)
        #expect(!draft.isDirty)

        draft.quotaColors[SubscriptionQuotaColors.fiveHourKey] = 0x445566
        #expect(draft.isDirty)

        draft.quotaColors = subscription.quotaColors
        #expect(!draft.isDirty)
    }

    @Test @MainActor
    func newEditorDraftTracksQuotaColorDirtyState() {
        let draft = SubscriptionEditorDraft(providerID: .kimi)
        #expect(!draft.isDirty)

        draft.quotaColors[SubscriptionQuotaColors.overallKey] = 0x112233
        #expect(draft.isDirty)

        draft.quotaColors = [:]
        #expect(!draft.isDirty)
    }

    @Test @MainActor
    func usageStorePersistsQuotaColorUpdates() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            defaults: defaults,
            loginItemManager: QuotaColorLoginItemManager(),
            notificationManager: QuotaColorNotificationManager()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("subscriptions.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageStore(settings: settings, metadataURL: fileURL)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        store.add(subscription)
        store.updateQuotaColors([SubscriptionQuotaColors.overallKey: 0x3366AA], for: subscription)

        #expect(store.subscriptions.first?.quotaColors[SubscriptionQuotaColors.overallKey] == 0x3366AA)

        let reloaded = UsageStore(settings: settings, metadataURL: fileURL)
        #expect(reloaded.subscriptions.first?.quotaColors[SubscriptionQuotaColors.overallKey] == 0x3366AA)
    }

    @Test @MainActor
    func usageStoreDisplayOrderFollowsArrayOrderNotCreationDate() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            defaults: defaults,
            loginItemManager: QuotaColorLoginItemManager(),
            notificationManager: QuotaColorNotificationManager()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("subscriptions.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageStore(settings: settings, metadataURL: fileURL)
        // 添加顺序与 createdAt 相反：显示顺序必须是数组顺序（手动排序语义），而非 createdAt。
        let later = Subscription(providerID: .kimi, name: "Later", authMethodID: .apiKey,
                                 createdAt: Date(timeIntervalSince1970: 2_000))
        let earlier = Subscription(providerID: .deepSeek, name: "Earlier", authMethodID: .apiKey,
                                   createdAt: Date(timeIntervalSince1970: 1_000))
        store.add(later)
        store.add(earlier)

        #expect(store.subscriptions.map(\.name) == ["Later", "Earlier"])
    }

    @Test @MainActor
    func usageStoreManualReorderPersistsAcrossReload() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            defaults: defaults,
            loginItemManager: QuotaColorLoginItemManager(),
            notificationManager: QuotaColorNotificationManager()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("subscriptions.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageStore(settings: settings, metadataURL: fileURL)
        let first = Subscription(providerID: .deepSeek, name: "First", authMethodID: .apiKey)
        let second = Subscription(providerID: .kimi, name: "Second", authMethodID: .apiKey)
        let third = Subscription(providerID: .zhipu, name: "Third", authMethodID: .apiKey)
        store.add(first)
        store.add(second)
        store.add(third)

        store.moveSubscriptions(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.subscriptions.map(\.name) == ["Second", "Third", "First"])

        store.moveSubscriptions(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.subscriptions.map(\.name) == ["First", "Second", "Third"])

        let reloaded = UsageStore(settings: settings, metadataURL: fileURL)
        #expect(reloaded.subscriptions.map(\.name) == ["First", "Second", "Third"])
    }

    @Test @MainActor
    func usageStoreSurfacesMetadataWriteFailuresInsteadOfSilentlyDropping() throws {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            defaults: defaults,
            loginItemManager: QuotaColorLoginItemManager(),
            notificationManager: QuotaColorNotificationManager()
        )
        let block = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-block-\(UUID().uuidString)", isDirectory: false)
        try Data("block".utf8).write(to: block)
        defer { try? FileManager.default.removeItem(at: block) }
        // 父路径是一个普通文件：createDirectory/写盘必然失败。
        let fileURL = block.appendingPathComponent("subscriptions.json")

        let store = UsageStore(settings: settings, metadataURL: fileURL)
        #expect(store.lastPersistenceError == nil)
        store.add(Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey))

        // 内存仍保留订阅（会话内可用），但写盘失败必须可见。
        #expect(store.subscriptions.count == 1)
        #expect(store.lastPersistenceError != nil)
    }
}

private final class QuotaColorLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

private final class QuotaColorNotificationManager: NotificationAuthorizationManaging, @unchecked Sendable {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) { completion(.success(true)) }
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) { completion(.authorized) }
}

extension QuotaAndKimiTests {
    @Test @MainActor
    func usageStoreDiscardsCancelledRefreshCompletion() async throws {
        let fixture = try UsageStoreFixture()
        defer { fixture.remove() }
        let gate = RefreshGate()
        let store = fixture.makeStore { subscription, _ in GateUsageProvider(subscription: subscription, gate: gate) }
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        store.add(subscription)

        store.refresh(subscription)
        await gate.waitUntilStarted()
        store.invalidateRefresh(for: subscription)
        store.refresh(subscription)
        await gate.waitUntilStarted(count: 2)
        await gate.completeSecond()
        await Task.yield()
        await Task.yield()
        await gate.completeFirst()
        await Task.yield()
        await Task.yield()

        #expect(store.snapshots[subscription.id]?.errorMessage == "second")
        #expect(store.lastSuccessfulRefreshAt != nil)
        #expect(!store.isRefreshing)
    }

    @Test @MainActor
    func usageStorePreservesCorruptMetadataAndBlocksMutations() throws {
        let fixture = try UsageStoreFixture(metadata: Data("corrupt metadata".utf8))
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.metadataURL)
        let store = fixture.makeStore()

        store.add(Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey))

        #expect(store.subscriptions.isEmpty)
        #expect(try Data(contentsOf: fixture.metadataURL) == original)
        #expect(store.lastPersistenceError != nil)

        try Data("[]".utf8).write(to: fixture.metadataURL)
        store.retryLoadingSubscriptions()
        let recovered = Subscription(providerID: .deepSeek, name: "Recovered", authMethodID: .apiKey)
        store.add(recovered)
        #expect(store.lastPersistenceError == nil)
        let persisted = try JSONDecoder().decode([Subscription].self, from: Data(contentsOf: fixture.metadataURL))
        #expect(persisted.map(\.id) == [recovered.id])
    }
}

@MainActor
private final class UsageStoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeterTests-\(UUID().uuidString)", isDirectory: true)
    let metadataURL: URL
    let credentialURL: URL
    private let suite = "TokenMeterTests.\(UUID().uuidString)"

    init(metadata: Data? = nil) throws {
        metadataURL = directory.appendingPathComponent("subscriptions.json")
        credentialURL = directory.appendingPathComponent("credentials.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let metadata { try metadata.write(to: metadataURL) }
    }

    func makeStore(providerFactory: @escaping UsageProviderFactory = { subscription, _ in UnsupportedUsageProvider(subscription: subscription) }) -> UsageStore {
        UsageStore(settings: makeSettings(), metadataURL: metadataURL,
                   credentialStore: CredentialStore(fileURL: credentialURL), providerFactory: providerFactory)
    }

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: suite)!, loginItemManager: QuotaColorLoginItemManager(), notificationManager: QuotaColorNotificationManager())
    }

    func remove() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RefreshGate {
    private var starts = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var secondContinuation: CheckedContinuation<Void, Never>?

    func fetch() async -> String {
        starts += 1
        let start = starts
        await withCheckedContinuation { continuation in
            if start == 1 { firstContinuation = continuation } else { secondContinuation = continuation }
        }
        return start == 1 ? "first" : "second"
    }

    func waitUntilStarted(count: Int = 1) async {
        while starts < count { await Task.yield() }
    }

    func completeFirst() { firstContinuation?.resume(); firstContinuation = nil }
    func completeSecond() { secondContinuation?.resume(); secondContinuation = nil }
}

private struct GateUsageProvider: UsageProvider {
    let subscription: Subscription
    let gate: RefreshGate

    func fetchUsage() async throws -> UsageSnapshot {
        UsageSnapshot(subscriptionID: subscription.id, providerID: subscription.providerID, quotas: [], updatedAt: .now, errorMessage: await gate.fetch(), state: .realtime)
    }
}
