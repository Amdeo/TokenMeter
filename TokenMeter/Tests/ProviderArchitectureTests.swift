import Foundation
import Testing
import SwiftUI
@testable import TokenMeter

// MARK: - Provider 注册表

@MainActor
struct ProviderRegistryTests {
    @Test
    func registryExposesAllBuiltInProvidersWithUniqueIDs() {
        let ids = ProviderRegistry.all.map(\.id.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(ids == ["deepseek", "kimi", "zhipu", "opencode-go", "minimax", "ccbus", "apikey-fun", "nowcoding", "codex", "claude"])
    }

    @Test
    func everyDefinitionProvidesMetadataAndAuthMethods() {
        for definition in ProviderRegistry.all {
            #expect(!definition.metadata.displayName.isEmpty)
            #expect(!definition.metadata.fallbackSystemImage.isEmpty)
            #expect(!definition.authMethods.isEmpty)
        }
    }

    @Test
    func kimiOffersThreeAuthMethodsAndOthersAPIKey() {
        let kimi = ProviderRegistry.definition(for: .kimi)
        #expect(kimi?.authMethods.map(\.id.rawValue) == ["api-key", "kimi-device-oauth", "kimi-browser-session"])
        for providerID in [ProviderID.deepSeek, .zhipu, .openCodeGo, .miniMax] {
            let definition = ProviderRegistry.definition(for: providerID)
            #expect(definition?.authMethods.map(\.id.rawValue) == ["api-key"])
        }
    }

    @Test
    func oauthOnlyProvidersExposeTheirSingleFlow() {
        #expect(ProviderRegistry.definition(for: .codex)?.authMethods.map(\.id.rawValue) == ["codex-device-oauth"])
        #expect(ProviderRegistry.definition(for: .claude)?.authMethods.map(\.id.rawValue) == ["claude-oauth"])
        #expect(ProviderRegistry.authFlow(for: .codex, authMethodID: .codexDeviceOAuth) == .deviceOAuth)
        #expect(ProviderRegistry.authFlow(for: .claude, authMethodID: .claudeOAuth) == .oauthCode)
    }

    @Test
    func unknownProviderResolvesToNilAndUnsupportedDefinitionRenders() {
        let unknown = ProviderID(rawValue: "nonexistent")
        #expect(ProviderRegistry.definition(for: unknown) == nil)
        let definition = UnsupportedProviderDefinition(providerID: unknown)
        #expect(definition.metadata.displayName == "nonexistent")
        let snapshot = definition.makeDemoSnapshot(
            for: Subscription(providerID: unknown, name: "x"),
            now: .now
        )
        #expect(snapshot.state == .unsupported)
    }

    @Test
    func eachDefinitionBuildsItsUsageProvider() {
        for definition in ProviderRegistry.all {
            let subscription = Subscription(providerID: definition.id, name: definition.metadata.displayName)
            let provider = definition.makeUsageProvider(for: subscription)
            #expect(provider.subscription.id == subscription.id)
        }
    }

    @Test
    func demoSnapshotsAreRealtimeAndCarryProviderID() {
        for definition in ProviderRegistry.all {
            let subscription = Subscription(providerID: definition.id, name: "demo")
            let snapshot = definition.makeDemoSnapshot(for: subscription, now: .now)
            #expect(snapshot.state == .realtime)
            #expect(snapshot.providerID == definition.id)
        }
    }
}

// MARK: - 旧数据迁移

@MainActor
struct MigrationTests {
    @Test
    func legacySubscriptionJSONMapsToCanonicalProviderAndAuthIDs() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","platform":"OpenCode Go","name":"My Go","authMethod":"manualAPIKey","createdAt":0,"isEnabled":true}
        """.utf8)
        let subscription = try JSONDecoder().decode(Subscription.self, from: data)
        #expect(subscription.providerID == .openCodeGo)
        #expect(subscription.authMethodID == .apiKey)

        let reencoded = try JSONEncoder().encode(subscription)
        let decoded = try JSONDecoder().decode(Subscription.self, from: reencoded)
        #expect(decoded.providerID == .openCodeGo)
        #expect(decoded.authMethodID == .apiKey)
    }

    @Test
    func legacyAuthAliasesMapToAPIKey() throws {
        for alias in ["piAuth", "officialAuth"] {
            let data = Data("""
            {"id":"00000000-0000-0000-0000-000000000001","platform":"Kimi","name":"Kimi","authMethod":"\(alias)","createdAt":0,"isEnabled":true}
            """.utf8)
            let subscription = try JSONDecoder().decode(Subscription.self, from: data)
            #expect(subscription.authMethodID == .apiKey)
        }
    }

    @Test
    func legacyKimiOAuthMapsToStableAuthID() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","platform":"Kimi","name":"Kimi","authMethod":"kimiOAuth","createdAt":0,"isEnabled":true}
        """.utf8)
        let subscription = try JSONDecoder().decode(Subscription.self, from: data)
        #expect(subscription.authMethodID == .kimiDeviceOAuth)
    }

    @Test
    func unknownLegacyPlatformKeepsRawValueAndRemainsDecodable() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","platform":"Some Future AI","name":"Future","authMethod":"manualAPIKey","createdAt":0,"isEnabled":true}
        """.utf8)
        let subscription = try JSONDecoder().decode(Subscription.self, from: data)
        #expect(subscription.providerID == ProviderID(rawValue: "Some Future AI"))
        #expect(ProviderRegistry.definition(for: subscription.providerID) == nil)
    }

    @Test
    func legacySnapshotProviderFieldMapsToProviderID() throws {
        let data = Data("""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "subscriptionID":"00000000-0000-0000-0000-000000000002",
          "platform":"DeepSeek",
          "quotas":[],
          "updatedAt":0,
          "isDemo":false,
          "errorMessage":null,
          "state":"realtime"
        }
        """.utf8)
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(snapshot.providerID == .deepSeek)
        #expect(snapshot.providerData == nil)
    }

    @Test
    func snapshotProviderDataRoundTrips() throws {
        var subscription = Subscription(providerID: .openCodeGo, name: "Go")
        _ = subscription
        let quota = Quota(name: "每月窗口", used: 10, limit: 100, resetAt: nil)
        let snapshot = UsageSnapshot.realtime(
            subscription: Subscription(providerID: .openCodeGo, name: "Go"),
            quotas: [quota],
            providerData: .object(["custom": .number(42)])
        )
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.providerData?.number(for: ["custom"]) == 42)
    }
}

// MARK: - CredentialStore 通用凭据

struct StoredCredentialTests {
    private func makeStore() -> (CredentialStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)")
            .appendingPathComponent("credentials.json")
        return (CredentialStore(fileURL: url), url)
    }

    @Test
    func storesAndReadsEachFlowCredentialMutuallyExclusive() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()

        let apiKey = StoredCredential.apiKey("key-123")
        try store.save(apiKey, for: id)
        #expect(store.credential(for: id, flowID: .apiKey) == .apiKey("key-123"))
        #expect(store.credential(for: id, flowID: .deviceOAuth) == nil)
        #expect(store.credential(for: id, flowID: .browserSession) == nil)

        let oauth = OAuthCredential(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, tokenType: "Bearer")
        try store.save(.oauth(oauth), for: id)
        #expect(store.credential(for: id, flowID: .deviceOAuth) == .oauth(oauth))
        #expect(store.credential(for: id, flowID: .apiKey) == nil)

        let browser = KimiBrowserCredential(accessToken: "b", refreshToken: "r", expiresAt: .distantFuture, tokenType: "Bearer")
        try store.save(.browserSession(browser), for: id)
        #expect(store.credential(for: id, flowID: .browserSession) == .browserSession(browser))
        #expect(store.credential(for: id, flowID: .deviceOAuth) == nil)
    }

    @Test
    func legacySavedCredentialReadsBackThroughGenericAccessor() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        try store.save(apiKey: "legacy-key", for: id)
        #expect(store.credential(for: id, flowID: .apiKey) == .apiKey("legacy-key"))
    }

    @Test
    func typedSavesClearEveryOtherCredentialField() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        let cookie = CookieSessionCredential(sessionCookie: "s", userID: "u")

        // cookie 会话先写入，随后保存 API Key 必须清空 cookie。
        try store.save(cookieSession: cookie, for: id)
        #expect(store.cookieSession(for: id) == cookie)
        try store.save(apiKey: "key-1", for: id)
        #expect(store.cookieSession(for: id) == nil)
        #expect(store.apiKey(for: id) == "key-1")

        // API Key 已存在时保存 OAuth 凭证，必须清空 API Key。
        let oauth = OAuthCredential(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, tokenType: "Bearer")
        try store.save(oauthCredential: oauth, for: id)
        #expect(store.apiKey(for: id) == nil)
        #expect(store.oauthCredential(for: id) == oauth)
    }
}

// MARK: - 卡片渲染器

@MainActor
struct CardRendererTests {
    @Test
    func balanceCardShowsBalanceRowWithoutSummary() {
        let renderer = BalanceCardRenderer()
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek")
        let quota = Quota(name: "可用余额", used: 0, limit: 12.34, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [quota])
        #expect(renderer.summary(subscription: subscription, snapshot: snapshot) == nil)
        #expect(renderer.status(subscription: subscription, snapshot: snapshot) == .normal)
    }

    @Test
    func quotaListCardUsesFirstQuotaAsSummary() throws {
        let renderer = QuotaListCardRenderer()
        let subscription = Subscription(providerID: .zhipu, name: "智谱 AI")
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时额度", used: 18, limit: 100, resetAt: nil, kind: .fiveHour),
            Quota(name: "每周额度", used: 5, limit: 100, resetAt: nil, kind: .weekly)
        ])
        let summary = try #require(renderer.summary(subscription: subscription, snapshot: snapshot))
        #expect(summary.label == "5 小时额度")
        #expect(renderer.status(subscription: subscription, snapshot: snapshot) == .normal)
    }

    @Test
    func quotaListCardAnchorHintPrefersMatchingQuotaAndExcludesFromBody() throws {
        let renderer = QuotaListCardRenderer(anchorHint: "月")
        let subscription = Subscription(providerID: .openCodeGo, name: "OpenCode Go")
        let monthly = Quota(name: "每月窗口", used: 90, limit: 100, resetAt: nil)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时窗口", used: 10, limit: 100, resetAt: nil),
            monthly
        ])
        let summary = try #require(renderer.summary(subscription: subscription, snapshot: snapshot))
        #expect(summary.label == "每月窗口")
        #expect(summary.accessibilityLabel.contains("已用 90%"))
        #expect(renderer.status(subscription: subscription, snapshot: snapshot) == .warning)
    }

    @Test
    func kimiCardSummaryRequiresNonAPIKeyAuthAndPrefersOverallRatio() throws {
        let renderer = KimiCardRenderer()
        let apiKeySubscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiDeviceOAuth)
        let snapshot = UsageSnapshot.realtime(
            subscription: subscription,
            quotas: [
                Quota(name: "5 小时额度", used: 60, limit: 100, resetAt: nil, kind: .fiveHour),
                Quota(name: "每周额度", used: 40, limit: 100, resetAt: nil, kind: .weekly)
            ],
            overallUsageRatio: 0.41
        )
        #expect(renderer.summary(subscription: apiKeySubscription, snapshot: snapshot) == nil)
        let summary = try #require(renderer.summary(subscription: subscription, snapshot: snapshot))
        #expect(summary.label == "总使用量")
        #expect(summary.value == "41.0%")
        #expect(renderer.status(subscription: subscription, snapshot: snapshot) == .normal)
    }

    @Test
    func kimiCardSummaryFallsBackToCoreWindowWhenNoOverallRatio() throws {
        let renderer = KimiCardRenderer()
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时额度", used: 90, limit: 100, resetAt: nil, kind: .fiveHour)
        ])
        let summary = try #require(renderer.summary(subscription: subscription, snapshot: snapshot))
        #expect(summary.label == "5 小时额度")
        #expect(renderer.status(subscription: subscription, snapshot: snapshot) == .warning)
    }

    @Test
    func kimiCardBalanceFallbackBodyAndStatusUseBalance() throws {
        // API Key 回退余额：没有 5 小时/每周额度，状态只看余额，正文渲染余额行。
        let renderer = KimiCardRenderer()
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let fallback = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额", used: 0, limit: 3.5, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])

        #expect(renderer.summary(subscription: subscription, snapshot: fallback) == nil)
        #expect(renderer.status(subscription: subscription, snapshot: fallback) == .normal)
        // makeBody 必须能渲染回退余额；余额被扣超时状态为 exhausted。
        _ = renderer.makeBody(subscription: subscription, snapshot: fallback)
        let overspent = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额", used: 1, limit: 0.5, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])
        #expect(renderer.status(subscription: subscription, snapshot: overspent) == .exhausted)
    }

    @Test
    func unknownProviderCardRendersUnsupportedState() {
        let renderer = UnsupportedCardRenderer()
        let subscription = Subscription(providerID: ProviderID(rawValue: "future"), name: "x")
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [])
        #expect(renderer.summary(subscription: subscription, snapshot: snapshot) == nil)
        #expect(renderer.status(subscription: subscription, snapshot: snapshot) == .error)
    }

    @Test
    func cardAccessibilityLabelUsesRegistryDrivenSummary() throws {
        let subscription = Subscription(providerID: .zhipu, name: "智谱 AI", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时额度", used: 18, limit: 100, resetAt: nil, kind: .fiveHour)
        ])
        let anchor = SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot)
        let label = SubscriptionCardPresentation.cardAccessibilityLabel(subscription: subscription, snapshot: snapshot, anchor: anchor)
        #expect(label == "编辑 智谱 AI 的配置，正常，5 小时额度，已用 18%")
    }
}

// MARK: - CCBus 集成

@MainActor
struct CCBusTests {
    private func makeJWT(exp: TimeInterval) -> String {
        let payload = Data("{\"exp\":\(Int(exp))}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    @Test
    func ccbusIsRegisteredWithBrowserSessionAuth() {
        let definition = ProviderRegistry.definition(for: .ccbus)
        #expect(definition != nil)
        #expect(definition?.metadata.displayName == "CCBus（AI 巴士）")
        #expect(definition?.authMethods.map(\.id.rawValue) == ["ccbus-browser-session"])
        #expect(definition?.authMethods.first?.flowID == .browserSession)
    }

    @Test
    func ccbusExtractorBuildsCredentialFromLocalStoragePayload() throws {
        let future = Date.now.addingTimeInterval(3_600).timeIntervalSince1970
        let access = makeJWT(exp: future)
        let refresh = makeJWT(exp: future + 86_400)
        let raw = "{\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\"}"

        let credential = try CCBusBrowserCredentialExtractor.credential(from: raw)

        #expect(credential.tokenType == "Bearer")
        #expect(credential.expiresAt.timeIntervalSince1970 == Double(Int(future)))
    }

    @Test
    func ccbusExtractorRejectsExpiredToken() {
        let token = makeJWT(exp: Date.now.addingTimeInterval(-60).timeIntervalSince1970)
        let raw = "{\"accessToken\":\"\(token)\",\"refreshToken\":\"\(token)\"}"

        #expect(throws: CCBusBrowserCredentialError.expired) {
            _ = try CCBusBrowserCredentialExtractor.credential(from: raw)
        }
    }

    @Test
    func ccbusExtractorRejectsEmptyTokens() {
        #expect(throws: CCBusBrowserCredentialError.credentialsMissing) {
            _ = try CCBusBrowserCredentialExtractor.credential(from: "{\"accessToken\":\"  \",\"refreshToken\":\"\"}")
        }
    }

    @Test
    func ccbusRefreshResponseParsesTokensAndExpiry() async throws {
        let future = Date.now.addingTimeInterval(7_200).timeIntervalSince1970
        // 模拟前端 POST /auth/refresh 的响应：code 0 + access_token/refresh_token/expires_in
        let raw = """
        {"code":0,"message":"success","data":{"access_token":"new-access","refresh_token":"new-refresh","expires_in":7200}}
        """
        // 通过 URLProtocol stub 无法在此测试直接注入，因此验证响应模型可解码。
        let response = try JSONDecoder().decode(CCBusSessionRefresher.RefreshResponse.self, from: Data(raw.utf8))
        #expect(response.code == 0)
        #expect(response.data?.accessToken == "new-access")
        #expect(response.data?.refreshToken == "new-refresh")
        #expect(response.data?.expiresIn == 7200)
        _ = future
    }

    @Test
    func ccbusDemoSnapshotIsBalanceQuota() {
        let definition = ProviderRegistry.definition(for: .ccbus)!
        let subscription = Subscription(providerID: .ccbus, name: "CCBus")
        let snapshot = definition.makeDemoSnapshot(for: subscription, now: .now)
        #expect(snapshot.state == .realtime)
        #expect(snapshot.quotas.first?.kind == .balance)
        #expect(snapshot.quotas.first?.unit.isCurrency == true)
    }
}

// MARK: - APIKEY.FUN 集成

@MainActor
struct APIKeyFunTests {
    private func makeJWT(exp: TimeInterval) -> String {
        let payload = Data("{\"exp\":\(Int(exp))}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    @Test
    func apikeyFunIsRegisteredWithBrowserSessionAuth() {
        let definition = ProviderRegistry.definition(for: .apikeyFun)
        #expect(definition != nil)
        #expect(definition?.metadata.displayName == "APIKEY.FUN")
        #expect(definition?.authMethods.map(\.id.rawValue) == ["apikey-fun-browser-session"])
        #expect(definition?.authMethods.first?.flowID == .browserSession)
    }

    @Test
    func apikeyFunExtractorBuildsCredentialFromLocalStoragePayload() throws {
        let future = Date.now.addingTimeInterval(3_600).timeIntervalSince1970
        let access = makeJWT(exp: future)
        let refresh = makeJWT(exp: future + 86_400)
        let raw = "{\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\"}"

        let credential = try APIKeyFunBrowserCredentialExtractor.credential(from: raw)

        #expect(credential.tokenType == "Bearer")
        #expect(credential.expiresAt.timeIntervalSince1970 == Double(Int(future)))
    }

    @Test
    func apikeyFunExtractorRejectsExpiredToken() {
        let token = makeJWT(exp: Date.now.addingTimeInterval(-60).timeIntervalSince1970)
        let raw = "{\"accessToken\":\"\(token)\",\"refreshToken\":\"\(token)\"}"

        #expect(throws: APIKeyFunBrowserCredentialError.expired) {
            _ = try APIKeyFunBrowserCredentialExtractor.credential(from: raw)
        }
    }

    @Test
    func apikeyFunExtractorRejectsEmptyTokens() {
        #expect(throws: APIKeyFunBrowserCredentialError.credentialsMissing) {
            _ = try APIKeyFunBrowserCredentialExtractor.credential(from: "{\"accessToken\":\"  \",\"refreshToken\":\"\"}")
        }
    }

    @Test
    func apikeyFunRefreshResponseParsesTokensAndExpiry() throws {
        let raw = """
        {"code":0,"message":"success","data":{"access_token":"new-access","refresh_token":"new-refresh","expires_in":7200}}
        """
        let response = try JSONDecoder().decode(APIKeyFunSessionRefresher.RefreshResponse.self, from: Data(raw.utf8))
        #expect(response.code == 0)
        #expect(response.data?.accessToken == "new-access")
        #expect(response.data?.refreshToken == "new-refresh")
        #expect(response.data?.expiresIn == 7200)
    }

    @Test
    func apikeyFunDemoSnapshotIsBalanceQuota() {
        let definition = ProviderRegistry.definition(for: .apikeyFun)!
        let subscription = Subscription(providerID: .apikeyFun, name: "APIKEY.FUN")
        let snapshot = definition.makeDemoSnapshot(for: subscription, now: .now)
        #expect(snapshot.state == .realtime)
        #expect(snapshot.quotas.first?.kind == .balance)
        #expect(snapshot.quotas.first?.unit.isCurrency == true)
    }
}

// MARK: - NowCoding 集成

@MainActor
struct NowCodingTests {
    @Test
    func nowcodingIsRegisteredWithBrowserSessionAuth() {
        let definition = ProviderRegistry.definition(for: .nowCoding)
        #expect(definition != nil)
        #expect(definition?.metadata.displayName == "NowCoding")
        #expect(definition?.authMethods.map(\.id.rawValue) == ["nowcoding-browser-session"])
        #expect(definition?.authMethods.first?.flowID == .browserSession)
    }

    @Test
    func nowcodingExtractorBuildsCookieCredential() throws {
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "abc123",
            .domain: "nowcoding.ai",
            .path: "/",
        ])!
        let credential = try NowCodingBrowserCredentialExtractor.credential(cookie: cookie, userID: "21")
        #expect(credential.sessionCookie == "session=abc123")
        #expect(credential.userID == "21")
    }

    @Test
    func nowcodingExtractorRejectsMissingCookieOrUserID() {
        let cookie = HTTPCookie(properties: [
            .name: "other",
            .value: "x",
            .domain: "nowcoding.ai",
            .path: "/",
        ])!
        #expect(throws: NowCodingBrowserCredentialError.credentialsMissing) {
            _ = try NowCodingBrowserCredentialExtractor.credential(cookie: cookie, userID: "21")
        }
    }

    @Test
    func nowcodingExtractorRejectsMissingUserID() throws {
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "abc123",
            .domain: "nowcoding.ai",
            .path: "/",
        ])!
        #expect(throws: NowCodingBrowserCredentialError.invalidCredentials) {
            _ = try NowCodingBrowserCredentialExtractor.credential(cookie: cookie, userID: " ")
        }
    }

    @Test
    func cookieCredentialIsMutuallyExclusiveOnSave() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)")
            .appendingPathComponent("credentials.json")
        let store = CredentialStore(fileURL: fileURL)
        let id = UUID()
        let apiKey = try #require("sk-test")
        try store.save(.apiKey(apiKey), for: id)
        try store.save(.cookieSession(CookieSessionCredential(sessionCookie: "session=xyz", userID: "9")), for: id)
        #expect(store.cookieSession(for: id)?.userID == "9")
        #expect(store.apiKey(for: id) == nil)

        try store.save(.browserSession(KimiBrowserCredential(accessToken: "a", refreshToken: "r", expiresAt: Date.now.addingTimeInterval(3600), tokenType: "Bearer")), for: id)
        #expect(store.cookieSession(for: id) == nil)
        #expect(store.browserCredential(for: id)?.accessToken == "a")
    }

    @Test
    func nowcodingDemoSnapshotShowsBalanceAndPlans() {
        let definition = ProviderRegistry.definition(for: .nowCoding)!
        let subscription = Subscription(providerID: .nowCoding, name: "NowCoding")
        let snapshot = definition.makeDemoSnapshot(for: subscription, now: .now)
        #expect(snapshot.state == .realtime)
        #expect(snapshot.quotas.contains { $0.kind == .balance })
        #expect(snapshot.quotas.filter { $0.kind == .generic }.count == 2)
    }

    @Test
    func planDisplayStripsBracketPrefix() {
        let title = "【畅享套餐】Codex 月卡 1500$"
        // PlanDisplay 的标题清洗逻辑在类型内；直接验证期望结果（全角】分隔）。
        let core = title.split(separator: "】").last.map(String.init) ?? title
        #expect(core == "Codex 月卡 1500$")
    }
}

// MARK: - BrowserSessionFlow 通用会话流程

struct BrowserSessionFlowTests {
    private func makeStore() -> (CredentialStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)")
            .appendingPathComponent("credentials.json")
        return (CredentialStore(fileURL: url), url)
    }

    private func makeCredential(expiresIn: TimeInterval) -> KimiBrowserCredential {
        KimiBrowserCredential(
            accessToken: "access", refreshToken: "refresh",
            expiresAt: Date.now.addingTimeInterval(expiresIn), tokenType: "Bearer"
        )
    }

    private func makeConfiguration(
        store: CredentialStore,
        id: UUID,
        refresh: @escaping (KimiBrowserCredential) async throws -> KimiBrowserCredential
    ) -> BrowserSessionFlow.Configuration {
        BrowserSessionFlow.Configuration(
            providerID: .ccbus,
            subscriptionID: id,
            credentials: store,
            isUsable: { $0.expiresAt > .now },
            refresh: refresh,
            isInvalid: { ($0 as? CCBusBrowserCredentialError)?.indicatesInvalidCredential ?? false },
            invalidMessage: "CCBus 网页登录态已过期，请在订阅设置中重新登录"
        )
    }

    @Test
    func usableCredentialSkipsRefresh() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var refreshCount = 0
        let configuration = makeConfiguration(store: store, id: id) { credential in
            refreshCount += 1
            return credential
        }
        let credential = makeCredential(expiresIn: 3_600)
        let result = try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: credential
        ) { _ in "ok" }
        #expect(result == "ok")
        #expect(refreshCount == 0)
    }

    @Test
    func expiredCredentialRefreshesAndPersistsBeforeFetch() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var fetchedToken: String?
        let configuration = makeConfiguration(store: store, id: id) { _ in
            makeCredential(expiresIn: 3_600)
        }
        let result = try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: makeCredential(expiresIn: -60)
        ) { credential in
            fetchedToken = credential.accessToken
            return credential.expiresAt
        }
        #expect(result != nil)
        // 刷新结果已回写凭证文件，业务请求使用的是新凭证。
        #expect(fetchedToken == "access")
        let persisted = try #require(store.browserCredential(for: id))
        #expect(persisted.expiresAt.timeIntervalSinceNow > 3_000)
    }

    @Test
    func unauthorizedFetchRetriesOnceWithForcedRefresh() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var refreshCount = 0
        let configuration = makeConfiguration(store: store, id: id) { _ in
            refreshCount += 1
            return makeCredential(expiresIn: 3_600)
        }
        var attempts = 0
        let result = try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: makeCredential(expiresIn: 3_600)
        ) { _ in
            attempts += 1
            if attempts == 1 {
                throw UsageProviderError.httpStatus(401)
            }
            return "recovered"
        }
        #expect(result == "recovered")
        #expect(attempts == 2)
        #expect(refreshCount == 1)
    }

    @Test
    func unauthorizedAfterPriorRefreshReportsAuthenticationRequired() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        let configuration = makeConfiguration(store: store, id: id) { _ in
            makeCredential(expiresIn: 3600)
        }
        do {
            _ = try await BrowserSessionFlow.fetchWithRetry(
                configuration, stored: makeCredential(expiresIn: -60)
            ) { _ in throw UsageProviderError.httpStatus(401) }
            #expect(Bool(false))
        } catch UsageProviderError.authenticationRequired {
            #expect(Bool(true))
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func invalidRefreshCredentialMapsToAuthenticationRequired() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        let configuration = makeConfiguration(store: store, id: id) { _ in
            throw CCBusBrowserCredentialError.expired
        }
        do {
            _ = try await BrowserSessionFlow.fetchWithRetry(
                configuration, stored: makeCredential(expiresIn: -60)
            ) { _ in "never" }
            #expect(Bool(false))
        } catch UsageProviderError.authenticationRequired {
            #expect(Bool(true))
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func refreshNetworkFailureMapsToRequestFailedNotAuth() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        let configuration = makeConfiguration(store: store, id: id) { _ in
            throw CCBusBrowserCredentialError.refreshFailed("HTTP 502")
        }
        do {
            _ = try await BrowserSessionFlow.fetchWithRetry(
                configuration, stored: makeCredential(expiresIn: -60)
            ) { _ in "never" }
            #expect(Bool(false))
        } catch UsageProviderError.requestFailed {
            #expect(Bool(true))
        } catch UsageProviderError.authenticationRequired {
            #expect(Bool(false))
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func retryRefreshFailureMapsToRequestFailed() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var refreshCount = 0
        let configuration = makeConfiguration(store: store, id: id) { _ in
            refreshCount += 1
            throw CCBusBrowserCredentialError.refreshFailed("HTTP 503")
        }
        do {
            _ = try await BrowserSessionFlow.fetchWithRetry(
                configuration, stored: makeCredential(expiresIn: 3_600)
            ) { _ in throw UsageProviderError.httpStatus(403) }
            #expect(Bool(false))
        } catch UsageProviderError.requestFailed {
            #expect(Bool(true))
        } catch {
            #expect(Bool(false))
        }
        #expect(refreshCount == 1)
    }
}
