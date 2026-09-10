import CryptoKit
import Foundation
import Testing
@testable import TokenMeter

// MARK: - 额度解析

struct ClaudeUsageTests {
    private func makeSubscription() -> Subscription {
        Subscription(providerID: .claude, name: "Claude", authMethodID: .claudeOAuth)
    }

    @Test
    func claudeUsageMapsAccountWideWindows() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2030-01-01T05:00:00.000Z"},
          "seven_day": {"utilization": 88, "resets_at": "2030-01-07T00:00:00Z"}
        }
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())

        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.quotas.map(\.name) == ["5 小时额度", "每周额度"])
        #expect(snapshot.quotas[0].used == 12.5)
        #expect(snapshot.quotas[0].limit == 100)
        #expect(snapshot.quotas[0].resetAt == ISO8601DateFormatter().date(from: "2030-01-01T05:00:00Z"))
        #expect(snapshot.quotas[1].used == 88)
    }

    @Test
    func claudeUsageFallsBackToLimitEntriesWhenBucketsAreAbsent() throws {
        // 参考实现：five_hour / seven_day 缺失时回退到 limits[] 的 session / weekly_all。
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {
          "limits": [
            {"kind": "session", "percent": 30, "resets_at": "2030-01-01T05:00:00Z"},
            {"kind": "weekly_all", "percent": 44, "resets_at": "2030-01-07T00:00:00Z"}
          ]
        }
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())

        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.quotas.map(\.used) == [30, 44])
    }

    @Test
    func claudeUsagePrefersBucketsOverLimitEntries() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {
          "five_hour": {"utilization": 7},
          "limits": [{"kind": "session", "percent": 99}]
        }
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].used == 7)
    }

    @Test
    func claudeUsageIncludesModelScopedWeeklyLimit() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {
          "five_hour": {"utilization": 1},
          "limits": [
            {"kind": "weekly_scoped", "percent": 5, "resets_at": "2030-01-07T00:00:00Z",
             "scope": {"model": {"display_name": "Opus 4.5"}}},
            {"kind": "weekly_scoped", "percent": 9, "scope": {"model": {"display_name": "Opus 4.5"}}}
          ]
        }
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())
        let scoped = snapshot.quotas.filter { $0.name.contains("Opus 4.5") }

        // 同名模型额度只保留第一次出现的窗口。
        #expect(scoped.count == 1)
        #expect(scoped[0].used == 5)
        #expect(scoped[0].kind == .generic)
        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .generic])
    }

    @Test
    func claudeUsageMapsSpendAsCurrencyQuota() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {
          "five_hour": {"utilization": 3},
          "spend": {
            "used": {"amount_minor": 1234, "currency": "USD", "exponent": 2},
            "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2}
          }
        }
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())
        let extra = try #require(snapshot.quotas.first { $0.unit.isCurrency })

        #expect(extra.name == "额外用量（USD）")
        #expect(extra.used == 12.34)
        #expect(extra.limit == 50)
    }

    @Test
    func claudeUsageMapsLegacyExtraUsage() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {
          "five_hour": {"utilization": 3},
          "extra_usage": {
            "is_enabled": true, "monthly_limit": 2000, "used_credits": 500,
            "decimal_places": 2, "currency": "USD"
          }
        }
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())
        let extra = try #require(snapshot.quotas.first { $0.unit.isCurrency })

        #expect(extra.used == 5)
        #expect(extra.limit == 20)
    }

    @Test
    func claudeUsageSkipsDisabledExtraUsage() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {"five_hour": {"utilization": 3}, "extra_usage": {"is_enabled": false, "used_credits": 500}}
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())

        #expect(!snapshot.quotas.contains { $0.unit.isCurrency })
    }

    @Test
    func claudeUsageClampsUtilizationToPercentRange() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data("""
        {"five_hour": {"utilization": 150}, "seven_day": {"utilization": -4}}
        """.utf8))

        let snapshot = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())

        #expect(snapshot.quotas.map(\.used) == [100, 0])
    }

    @Test
    func claudeUsageRejectsPayloadWithoutAnyWindow() throws {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(#"{"limits": []}"#.utf8))

        #expect {
            _ = try ClaudeUsageProvider.parseUsage(response, subscription: makeSubscription())
        } throws: { error in
            guard case let UsageProviderError.invalidResponse(providerID, _) = error else { return false }
            return providerID == .claude
        }
    }
}

// MARK: - OAuth 授权码流程

struct ClaudeOAuthTests {
    @Test
    func claudePKCEProducesVerifierChallengeAndState() {
        let pkce = ClaudeOAuthService.makePKCE()

        // RFC 7636：verifier 为 43–128 个 URL 安全字符，challenge 为 verifier 的 S256。
        #expect(pkce.verifier.count >= 43)
        #expect(pkce.verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
        #expect(pkce.state.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) })
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(pkce.challenge == expected)
        #expect(ClaudeOAuthService.makePKCE().verifier != pkce.verifier)
    }

    @Test
    func claudeAuthorizationURLCarriesRequiredParameters() throws {
        let pkce = ClaudeOAuthService.makePKCE()
        let url = ClaudeOAuthService.authorizationURL(pkce: pkce)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(components.host == "claude.ai")
        #expect(components.path == "/oauth/authorize")
        #expect(value("client_id") == ClaudeOAuthService.clientID)
        #expect(value("response_type") == "code")
        #expect(value("redirect_uri") == ClaudeOAuthService.redirectURI)
        #expect(value("code_challenge") == pkce.challenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == pkce.state)
        #expect(value("code") == "true")
        #expect(value("scope")?.contains("user:inference") == true)
    }

    @Test
    func claudeAuthorizationInputParsesCallbackURL() {
        let parsed = ClaudeOAuthService.parseAuthorizationInput(
            "http://localhost:54545/callback?code=abc-123&state=xyz",
            fallbackState: "fallback"
        )

        #expect(parsed?.code == "abc-123")
        #expect(parsed?.state == "xyz")
    }

    @Test
    func claudeAuthorizationInputParsesCodeWithState() {
        let parsed = ClaudeOAuthService.parseAuthorizationInput("abc-123#xyz", fallbackState: "fallback")

        #expect(parsed?.code == "abc-123")
        #expect(parsed?.state == "xyz")
    }

    @Test
    func claudeAuthorizationInputFallsBackToGeneratedStateForBareCode() {
        let parsed = ClaudeOAuthService.parseAuthorizationInput("  abc-123  ", fallbackState: "generated")

        #expect(parsed?.code == "abc-123")
        #expect(parsed?.state == "generated")
        #expect(ClaudeOAuthService.parseAuthorizationInput("   ", fallbackState: "generated") == nil)
    }

    @Test
    func claudeRefreshKeepsOldRefreshTokenAndAccountIDWhenOmitted() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let data = Data(#"{"access_token":"new-access","expires_in":28800}"#.utf8)

        let credential = try ClaudeOAuthService.credential(
            from: data,
            now: now,
            fallbackAccountID: "account-uuid",
            fallbackRefreshToken: "old-refresh"
        )

        #expect(credential.accessToken == "new-access")
        #expect(credential.refreshToken == "old-refresh")
        #expect(credential.accountID == "account-uuid")
        #expect(credential.expiresAt == now.addingTimeInterval(28_800))
        #expect(credential.tokenType == "Bearer")
    }

    @Test
    func claudeCodeExchangeRequiresRefreshToken() {
        let data = Data(#"{"access_token":"access","expires_in":28800}"#.utf8)

        #expect {
            _ = try ClaudeOAuthService.credential(
                from: data,
                now: .now,
                fallbackAccountID: nil,
                fallbackRefreshToken: nil
            )
        } throws: { error in
            guard case ClaudeOAuthError.invalidResponse = error else { return false }
            return true
        }
    }

    @Test
    func claudeCredentialPrefersResponseAccountID() throws {
        let data = Data("""
        {
          "access_token": "access", "refresh_token": "refresh", "expires_in": 3600,
          "account": {"uuid": "fresh-uuid"}
        }
        """.utf8)

        let credential = try ClaudeOAuthService.credential(
            from: data,
            now: .now,
            fallbackAccountID: "stale-uuid",
            fallbackRefreshToken: "old-refresh"
        )

        #expect(credential.accountID == "fresh-uuid")
    }
}

// MARK: - 额度请求的网络路径（注入传输层）

struct ClaudeUsageNetworkTests {
    private func makeTemporaryCredentialStore() -> (CredentialStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterClaudeTests-\(UUID().uuidString)")
            .appendingPathComponent("credentials.json")
        return (CredentialStore(fileURL: url), url)
    }

    private func storeStaleCredential(_ store: CredentialStore, _ subscriptionID: UUID) throws {
        try store.save(oauthCredential: OAuthCredential(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: .distantFuture,
            tokenType: "Bearer",
            accountID: "acc-uuid"
        ), for: subscriptionID)
    }

    private func makeProvider(
        stub: HTTPStub,
        store: CredentialStore,
        subscriptionID: UUID
    ) async -> ClaudeUsageProvider {
        let transport = await stub.transport
        return ClaudeUsageProvider(
            subscription: Subscription(id: subscriptionID, providerID: .claude, name: "Claude", authMethodID: .claudeOAuth),
            credentials: store,
            oauthService: ClaudeOAuthService(transport: transport),
            transport: transport
        )
    }

    private static let tokenBody = Data(
        #"{"access_token":"fresh","refresh_token":"refresh-2","expires_in":28800}"#.utf8
    )
    private static let usageBody = Data(
        #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20.5}}"#.utf8
    )

    @Test
    func claudeUsageRefreshesOnceAfterUnauthorizedAndRetries() async throws {
        let (store, url) = makeTemporaryCredentialStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subscriptionID = UUID()
        try storeStaleCredential(store, subscriptionID)

        let stub = HTTPStub { path, index in
            switch path {
            case "/api/oauth/usage":
                guard index > 0 else { return (401, Data()) }
                return (200, Self.usageBody)
            case "/v1/oauth/token":
                return (200, Self.tokenBody)
            default:
                return (404, Data())
            }
        }

        let provider = await makeProvider(stub: stub, store: store, subscriptionID: subscriptionID)
        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.quotas.map(\.used) == [10, 20.5])
        let usageCalls = await stub.callCount(path: "/api/oauth/usage")
        let tokenCalls = await stub.callCount(path: "/v1/oauth/token")
        #expect(usageCalls == 2)
        #expect(tokenCalls == 1)
        #expect(store.oauthCredential(for: subscriptionID)?.refreshToken == "refresh-2")
    }

    @Test
    func claudeUsageStopsAfterOneRefreshWhenStillUnauthorized() async throws {
        let (store, url) = makeTemporaryCredentialStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subscriptionID = UUID()
        try storeStaleCredential(store, subscriptionID)

        // 刷新后仍 401：必须只刷新一次并以认证失效结束，不得无限重试。
        let stub = HTTPStub { path, _ in
            switch path {
            case "/api/oauth/usage":
                return (401, Data())
            case "/v1/oauth/token":
                return (200, Self.tokenBody)
            default:
                return (404, Data())
            }
        }

        let provider = await makeProvider(stub: stub, store: store, subscriptionID: subscriptionID)
        do {
            _ = try await provider.fetchUsage()
            Issue.record("应当以认证失效结束")
        } catch let error as UsageProviderError {
            guard case .authenticationRequired = error else {
                Issue.record("错误的分类：\(error)")
                return
            }
        }

        let usageCalls = await stub.callCount(path: "/api/oauth/usage")
        let tokenCalls = await stub.callCount(path: "/v1/oauth/token")
        #expect(usageCalls == 2)
        #expect(tokenCalls == 1)
    }

    @Test
    func claudeUsageReportsRateLimitWithoutRetrying() async throws {
        let (store, url) = makeTemporaryCredentialStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subscriptionID = UUID()
        try storeStaleCredential(store, subscriptionID)

        // 429 按来源 IP 限流：不重试、不刷新，直接提示稍后重试。
        let stub = HTTPStub { path, _ in
            switch path {
            case "/api/oauth/usage":
                return (429, Data())
            case "/v1/oauth/token":
                return (200, Self.tokenBody)
            default:
                return (404, Data())
            }
        }

        let provider = await makeProvider(stub: stub, store: store, subscriptionID: subscriptionID)
        do {
            _ = try await provider.fetchUsage()
            Issue.record("应当以限流失败结束")
        } catch let error as UsageProviderError {
            guard case .requestFailed = error else {
                Issue.record("错误的分类：\(error)")
                return
            }
        }

        let usageCalls = await stub.callCount(path: "/api/oauth/usage")
        let tokenCalls = await stub.callCount(path: "/v1/oauth/token")
        #expect(usageCalls == 1)
        #expect(tokenCalls == 0)
    }
}
