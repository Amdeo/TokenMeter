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
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
        // 稳定 ID 一经发布不可改：小写字母 + 短横线。顺序由 ProviderCatalog 决定，新增供应商不必改本测试。
        #expect(ids.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") && !$0.isEmpty })
        #expect(ids == ProviderCatalog.providers.map(\.id.rawValue))
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

    /// 编辑页不再按供应商分派：每种认证流程所需的行为必须由认证方式自己声明，
    /// 否则新增供应商时会静默拿到错误的登录配置或无法启动授权。
    @Test
    func everyAuthMethodDeclaresTheBehaviourItsFlowNeeds() {
        for definition in ProviderRegistry.all {
            for method in definition.authMethods {
                switch method.flowID {
                case .apiKey:
                    break
                case .browserSession:
                    #expect(method.loginRecipe != nil, "\(definition.id.rawValue) 的 \(method.id.rawValue) 缺少登录配方")
                case .deviceOAuth:
                    #expect(method.deviceAuthorization != nil, "\(definition.id.rawValue) 的 \(method.id.rawValue) 缺少设备授权实现")
                case .oauthCode:
                    #expect(method.authorizationCode != nil, "\(definition.id.rawValue) 的 \(method.id.rawValue) 缺少授权码实现")
                }
            }
        }
    }

    @Test
    func unknownProviderResolvesToNilAndUnsupportedDefinitionRenders() async {
        let unknown = ProviderID(rawValue: "nonexistent")
        #expect(ProviderRegistry.definition(for: unknown) == nil)
        let definition = UnsupportedProviderDefinition(providerID: unknown)
        #expect(definition.metadata.displayName == "nonexistent")
        // 未知供应商刷新时抛 unsupported，不崩溃也不误报网络错误。
        let provider = definition.makeUsageProvider(for: Subscription(providerID: unknown, name: "x"))
        do {
            _ = try await provider.fetchUsage()
            Issue.record("未知供应商应抛 unsupported")
        } catch UsageProviderError.unsupported(let providerID) {
            #expect(providerID == unknown)
        } catch {
            Issue.record("错误的分类：\(error)")
        }
    }

    /// 卡片分组只看额度行自带的 group 元数据（显示名可能重复，不能当身份）。
    @Test
    func siyuCardGroupsWindowsByPlanGroup() {
        func window(_ key: String, _ title: String, _ name: String) -> Quota {
            Quota(
                name: "\(title) · \(name)",
                used: 10, limit: 100, resetAt: nil,
                kind: .generic,
                group: .init(key: key, title: title)
            )
        }
        let quotas = [
            window("plan.1", "DeepSeek大月卡", "每日"),
            window("plan.1", "DeepSeek大月卡", "每周"),
            window("plan.1", "DeepSeek大月卡", "每月"),
            window("plan.2", "DeepSeek月卡", "每日"),
            window("plan.2", "DeepSeek月卡", "每周"),
            window("plan.2", "DeepSeek月卡", "每月"),
        ]

        let groups = SiyuCardRenderer.planGroups(quotas)

        #expect(groups.compactMap(\.title) == ["DeepSeek大月卡", "DeepSeek月卡"])
        #expect(groups.map(\.key) == ["plan.1", "plan.2"])
        #expect(groups.allSatisfy { $0.windows.count == 3 })
        #expect(groups.first?.windows.map(SiyuCardRenderer.rowTitle) == ["每日", "每周", "每月"])
    }

    @Test
    func eachDefinitionBuildsItsUsageProvider() {
        for definition in ProviderRegistry.all {
            let subscription = Subscription(providerID: definition.id, name: definition.metadata.displayName)
            let provider = definition.makeUsageProvider(for: subscription)
            #expect(provider.subscription.id == subscription.id)
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

        let browser = BrowserTokenCredential(accessToken: "b", refreshToken: "r", expiresAt: .distantFuture, tokenType: "Bearer")
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
    func quotaListCardAnchorHintPrefersMatchingQuotaAndExcludesFromBody() throws {
        let renderer = QuotaListCardRenderer(anchorHint: "月")
        let subscription = Subscription(providerID: .openCodeGo, name: "OpenCode Go")
        let monthly = Quota(name: "每月窗口", used: 90, limit: 100, resetAt: nil)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时窗口", used: 10, limit: 100, resetAt: nil),
            monthly
        ])
        let summary = try #require(renderer.summary(subscription: subscription, snapshot: snapshot))
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

// MARK: - token 型网页登录态

/// Kimi / CCBus / APIKEY.FUN / Siyu 共用一套 localStorage 提取器与错误类型，
/// 同一组用例覆盖四个站点的差异（token 键名、refresh token 约束）。
struct BrowserTokenSiteTests {
    private static let sites: [BrowserTokenSite] = [.kimi, .ccbus, .apiKeyFun, .siyu]

    private static func makeJWT(exp: TimeInterval) -> String {
        let payload = Data("{\"exp\":\(Int(exp))}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private static func payload(access: String, refresh: String) -> String {
        "{\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\"}"
    }

    @Test(arguments: sites)
    func extractorBuildsCredentialFromLocalStoragePayload(_ site: BrowserTokenSite) throws {
        let future = Date.now.addingTimeInterval(3_600).timeIntervalSince1970
        let raw = Self.payload(
            access: Self.makeJWT(exp: future), refresh: Self.makeJWT(exp: future + 86_400)
        )

        let credential = try site.credential(from: raw)

        #expect(credential.tokenType == "Bearer")
        #expect(credential.expiresAt.timeIntervalSince1970 == Double(Int(future)))
    }

    @Test(arguments: sites)
    func extractorRejectsExpiredToken(_ site: BrowserTokenSite) {
        let token = Self.makeJWT(exp: Date.now.addingTimeInterval(-60).timeIntervalSince1970)

        #expect(throws: BrowserLoginError.expired(provider: site.displayName)) {
            _ = try site.credential(from: Self.payload(access: token, refresh: token))
        }
    }

    @Test(arguments: sites)
    func extractorRejectsEmptyTokens(_ site: BrowserTokenSite) {
        #expect(throws: BrowserLoginError.credentialsMissing(provider: site.displayName)) {
            _ = try site.credential(from: Self.payload(access: "  ", refresh: ""))
        }
    }

    @Test(arguments: sites)
    func extractorRejectsMalformedPayload(_ site: BrowserTokenSite) {
        #expect(throws: BrowserLoginError.invalidCredentials(provider: site.displayName)) {
            _ = try site.credential(from: "not json")
        }
    }

    /// refresh token 只有 Kimi 要求是带 exp 的 JWT；其余站点允许不透明字符串。
    @Test
    func refreshTokenJWTRequirementIsKimiOnly() throws {
        let access = Self.makeJWT(exp: Date.now.addingTimeInterval(3_600).timeIntervalSince1970)
        let raw = Self.payload(access: access, refresh: "opaque-refresh")

        #expect(throws: BrowserLoginError.invalidCredentials(provider: BrowserTokenSite.kimi.displayName)) {
            _ = try BrowserTokenSite.kimi.credential(from: raw)
        }
        #expect(throws: Never.self) {
            _ = try BrowserTokenSite.ccbus.credential(from: raw)
        }
    }

    @Test
    func refreshResponseParsesTokensAndExpiry() throws {
        // 模拟前端 POST /auth/refresh 的响应：code 0 + access_token/refresh_token/expires_in
        let raw = """
        {"code":0,"message":"success","data":{"access_token":"new-access","refresh_token":"new-refresh","expires_in":7200}}
        """
        let response = try JSONDecoder().decode(BrowserSessionRefresher.RefreshResponse.self, from: Data(raw.utf8))
        #expect(response.code == 0)
        #expect(response.data?.accessToken == "new-access")
        #expect(response.data?.refreshToken == "new-refresh")
        #expect(response.data?.expiresIn == 7200)
    }
}

// MARK: - CCBus 集成

@MainActor
struct CCBusTests {
    @Test
    func ccbusIsRegisteredWithBrowserSessionAuth() {
        let definition = ProviderRegistry.definition(for: .ccbus)
        #expect(definition != nil)
        #expect(definition?.metadata.displayName == "CCBus（AI 巴士）")
        #expect(definition?.authMethods.map(\.id.rawValue) == ["ccbus-browser-session"])
        #expect(definition?.authMethods.first?.flowID == .browserSession)
    }

}

// MARK: - APIKEY.FUN 集成

@MainActor
struct APIKeyFunTests {
    @Test
    func apikeyFunIsRegisteredWithBrowserSessionAuth() {
        let definition = ProviderRegistry.definition(for: .apikeyFun)
        #expect(definition != nil)
        #expect(definition?.metadata.displayName == "APIKEY.FUN")
        #expect(definition?.authMethods.map(\.id.rawValue) == ["apikey-fun-browser-session"])
        #expect(definition?.authMethods.first?.flowID == .browserSession)
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
    func cookieExtractorBuildsCredentialFromDeclaredSite() throws {
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "abc123",
            .domain: "nowcoding.ai",
            .path: "/",
        ])!
        let credential = try BrowserCookieCredential.credential(
            cookie: cookie, name: "session", userID: "21", displayName: "NowCoding"
        )
        #expect(credential.sessionCookie == "session=abc123")
        #expect(credential.userID == "21")
    }

    @Test
    func cookieExtractorRejectsMissingCookie() {
        let cookie = HTTPCookie(properties: [
            .name: "other",
            .value: "x",
            .domain: "nowcoding.ai",
            .path: "/",
        ])!
        #expect(throws: BrowserLoginError.credentialsMissing(provider: "NowCoding")) {
            _ = try BrowserCookieCredential.credential(
                cookie: cookie, name: "session", userID: "21", displayName: "NowCoding"
            )
        }
    }

    @Test
    func cookieExtractorRejectsMissingUserID() throws {
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "abc123",
            .domain: "nowcoding.ai",
            .path: "/",
        ])!
        #expect(throws: BrowserLoginError.invalidCredentials(provider: "NowCoding")) {
            _ = try BrowserCookieCredential.credential(
                cookie: cookie, name: "session", userID: " ", displayName: "NowCoding"
            )
        }
    }

    @Test
    func cookieCredentialIsMutuallyExclusiveOnSave() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)")
            .appendingPathComponent("credentials.json")
        let store = CredentialStore(fileURL: fileURL)
        let id = UUID()
        let apiKey = "sk-test"
        try store.save(.apiKey(apiKey), for: id)
        try store.save(.cookieSession(CookieSessionCredential(sessionCookie: "session=xyz", userID: "9")), for: id)
        #expect(store.cookieSession(for: id)?.userID == "9")
        #expect(store.apiKey(for: id) == nil)

        try store.save(.browserSession(BrowserTokenCredential(accessToken: "a", refreshToken: "r", expiresAt: Date.now.addingTimeInterval(3600), tokenType: "Bearer")), for: id)
        #expect(store.cookieSession(for: id) == nil)
        #expect(store.browserCredential(for: id)?.accessToken == "a")
    }

}

// MARK: - Siyu API 集成

@MainActor
struct SiyuTests {
    @Test
    func siyuIsRegisteredWithBrowserSessionAuth() {
        let definition = ProviderRegistry.definition(for: .siyu)
        #expect(definition != nil)
        #expect(definition?.metadata.displayName == "Siyu API")
        #expect(definition?.authMethods.map(\.id.rawValue) == ["siyu-browser-session"])
        #expect(definition?.authMethods.first?.flowID == .browserSession)
    }

    // MARK: - 过期订阅排除

    private func makeItem(
        status: String,
        expiresAt: String?,
        dailyUsage: Double = 0,
        weeklyUsage: Double = 0,
        monthlyUsage: Double = 2472,
        dailyLimit: Double = 0,
        weeklyLimit: Double = 0,
        monthlyLimit: Double = 35000,
        dailyWindowStart: String? = nil,
        weeklyWindowStart: String? = nil,
        monthlyWindowStart: String? = nil
    ) -> SubscriptionsResponse.Item {
        SubscriptionsResponse.Item(
            status: status,
            dailyUsageUSD: dailyUsage,
            weeklyUsageUSD: weeklyUsage,
            monthlyUsageUSD: monthlyUsage,
            dailyWindowStart: dailyWindowStart,
            weeklyWindowStart: weeklyWindowStart,
            monthlyWindowStart: monthlyWindowStart,
            expiresAt: expiresAt,
            group: SubscriptionsResponse.Item.Group(
                name: "DeepSeek大月卡",
                dailyLimitUSD: dailyLimit,
                weeklyLimitUSD: weeklyLimit,
                monthlyLimitUSD: monthlyLimit
            )
        )
    }

    @Test
    func siyuFiltersOutExpiredSubscriptions() {
        let now = Date.now
        let future = SiyuDate.parse("2099-01-01T00:00:00.000000+08:00")!
        let past = SiyuDate.parse("2020-01-01T00:00:00.000000+08:00")!

        let items = [
            makeItem(status: "active", expiresAt: "2099-01-01T00:00:00.000000+08:00"),
            makeItem(status: "active", expiresAt: "2020-01-01T00:00:00.000000+08:00"),
            makeItem(status: "expired", expiresAt: "2099-01-01T00:00:00.000000+08:00"),
            makeItem(status: "active", expiresAt: nil),
        ]

        let active = SiyuUsageProvider.activeSubscriptions(items, now: now)

        #expect(active.count == 1)
        #expect(active.first?.expiresAt == future)
        #expect(active.first?.name == "DeepSeek大月卡")
        _ = past
    }

    @Test
    func siyuParsesDailyWeeklyMonthlyWindowsAndResetTimes() throws {
        // 对齐线上 /subscriptions/active 响应：三个窗口各自带用量、限额与窗口起点。
        let json = """
        {
          "code": 0,
          "message": "success",
          "data": [
            {
              "id": 1470,
              "status": "active",
              "expires_at": "2099-01-01T00:00:00.000000+08:00",
              "daily_usage_usd": 383,
              "weekly_usage_usd": 2565,
              "monthly_usage_usd": 2565,
              "daily_window_start": "2026-09-12T00:00:00+08:00",
              "weekly_window_start": "2026-09-07T16:39:08.699592+08:00",
              "monthly_window_start": "2026-09-07T16:39:08.699592+08:00",
              "group": {
                "id": 17,
                "name": "DeepSeek大月卡",
                "status": "active",
                "daily_limit_usd": 2000,
                "weekly_limit_usd": 10000,
                "monthly_limit_usd": 35000
              }
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(SubscriptionsResponse.self, from: Data(json.utf8))
        let active = try #require(SiyuUsageProvider.activeSubscriptions(response.data ?? [], now: .now).first)

        #expect(active.name == "DeepSeek大月卡")
        #expect(active.windows.map(\.title) == ["每日", "每周", "每月"])
        #expect(active.windows.map(\.used) == [383, 2565, 2565])
        #expect(active.windows.map(\.limit) == [2000, 10000, 35000])

        // 重置时刻 = 窗口起点 + 1d/7d/30d。
        let dailyStart = try #require(SiyuDate.parse("2026-09-12T00:00:00+08:00"))
        let weeklyStart = try #require(SiyuDate.parse("2026-09-07T16:39:08.699592+08:00"))
        #expect(active.windows[0].resetAt == dailyStart.addingTimeInterval(86_400))
        #expect(active.windows[1].resetAt == weeklyStart.addingTimeInterval(7 * 86_400))
        #expect(active.windows[2].resetAt == weeklyStart.addingTimeInterval(30 * 86_400))
    }

    @Test
    func siyuWindowQuotasGroupByPlanKey() {
        let subscription = Subscription(providerID: .siyu, name: "Siyu API")
        let windows = [
            SiyuUsageProvider.UsageWindow.daily(used: 370, limit: 2000, windowStart: nil),
            SiyuUsageProvider.UsageWindow.weekly(used: 2552, limit: 10000, windowStart: nil),
            SiyuUsageProvider.UsageWindow.monthly(used: 2552, limit: 35000, windowStart: nil),
        ].compactMap { $0 }
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            SiyuUsageProvider.windowQuotas(key: "plan-1", title: "DeepSeek大月卡", windows: windows, expiresAt: .now),
            SiyuUsageProvider.windowQuotas(key: "plan-2", title: "DeepSeek月卡", windows: windows, expiresAt: .now),
        ].flatMap { $0 })

        let groups = SiyuCardRenderer.planGroups(snapshot.quotas)
        #expect(groups.map(\.key) == ["plan-1", "plan-2"])
        #expect(groups.compactMap(\.title) == ["DeepSeek大月卡", "DeepSeek月卡"])
        #expect(groups.allSatisfy { $0.windows.count == 3 })
        #expect(SiyuCardRenderer.rowTitle(groups[1].windows[1]) == "每周")
    }

    /// 服务端没给套餐名时两条订阅都用兜底名「订阅」：
    /// 分组必须靠 provider 给出的分组键，名字相同也要分成两个段落。
    @Test
    func siyuPlansWithSameDisplayNameStaySeparateGroups() throws {
        let json = """
        {"code":0,"message":"success","data":[\
        {"id":1,"status":"active","expires_at":"2099-01-01T00:00:00.000000+08:00","monthly_usage_usd":10,"group":{"monthly_limit_usd":100}},\
        {"id":2,"status":"active","expires_at":"2099-01-01T00:00:00.000000+08:00","monthly_usage_usd":20,"group":{"monthly_limit_usd":200}}]}
        """
        let response = try JSONDecoder().decode(SubscriptionsResponse.self, from: Data(json.utf8))
        let quotas = SiyuUsageProvider.activeSubscriptions(response.data ?? [], now: .now)
            .flatMap { SiyuUsageProvider.windowQuotas(key: $0.key, title: $0.name, windows: $0.windows, expiresAt: $0.expiresAt) }

        let groups = SiyuCardRenderer.planGroups(quotas)
        #expect(groups.count == 2)
        #expect(groups.compactMap(\.title) == ["订阅", "订阅"])
        #expect(groups.map { $0.windows.first?.limit } == [100, 200])
    }

    /// 服务端只给了月限额：没有上限的窗口没有可展示的进度，不能渲染成 0 上限的「已用尽」行。
    @Test
    func siyuOmitsWindowsWithoutLimits() throws {
        let json = """
        {
          "code": 0,
          "message": "success",
          "data": [
            {
              "id": 1470,
              "status": "active",
              "expires_at": "2099-01-01T00:00:00.000000+08:00",
              "daily_usage_usd": 383,
              "weekly_usage_usd": 2565,
              "monthly_usage_usd": 2565,
              "group": {
                "id": 17,
                "name": "DeepSeek大月卡",
                "status": "active",
                "monthly_limit_usd": 35000
              }
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(SubscriptionsResponse.self, from: Data(json.utf8))
        let active = try #require(SiyuUsageProvider.activeSubscriptions(response.data ?? [], now: .now).first)

        #expect(active.windows.map(\.title) == ["每月"])
        #expect(active.windows.map(\.limit) == [35000])
    }

    /// 一条订阅完全没有限额时没有任何进度行可展示，整条省略。
    @Test
    func siyuDropsPlansWithoutAnyLimit() throws {
        let json = """
        {
          "code": 0,
          "message": "success",
          "data": [
            {
              "id": 1470,
              "status": "active",
              "expires_at": "2099-01-01T00:00:00.000000+08:00",
              "daily_usage_usd": 383,
              "group": {
                "id": 17,
                "name": "DeepSeek大月卡",
                "status": "active"
              }
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(SubscriptionsResponse.self, from: Data(json.utf8))

        #expect(SiyuUsageProvider.activeSubscriptions(response.data ?? [], now: .now).isEmpty)
    }

    @Test
    func siyuParsesFractionalSecondDates() {
        #expect(SiyuDate.parse("2026-10-07T16:34:37.662424+08:00") != nil)
        #expect(SiyuDate.parse("2099-01-01T00:00:00.000000+08:00") != nil)
        #expect(SiyuDate.parse("not-a-date") == nil)
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

    private func makeCredential(expiresIn: TimeInterval) -> BrowserTokenCredential {
        BrowserTokenCredential(
            accessToken: "access", refreshToken: "refresh",
            expiresAt: Date.now.addingTimeInterval(expiresIn), tokenType: "Bearer"
        )
    }

    private func makeConfiguration(
        store: CredentialStore,
        id: UUID,
        refresh: @escaping (BrowserTokenCredential) async throws -> BrowserTokenCredential
    ) -> BrowserSessionFlow.Configuration {
        BrowserSessionFlow.Configuration(
            providerID: .ccbus,
            subscriptionID: id,
            credentials: store,
            providerName: BrowserTokenSite.ccbus.displayName,
            isUsable: { $0.expiresAt > .now },
            refresh: refresh
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
        _ = try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: makeCredential(expiresIn: -60)
        ) { credential in
            fetchedToken = credential.accessToken
            return credential.expiresAt
        }
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
            throw BrowserLoginError.expired(provider: "CCBus")
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
            throw BrowserLoginError.refreshFailed(provider: "CCBus", message: "HTTP 502")
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
            throw BrowserLoginError.refreshFailed(provider: "CCBus", message: "HTTP 503")
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

