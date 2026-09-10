import Foundation
import Testing
@testable import TokenMeter

// MARK: - Codex OAuth 与额度解析

struct CodexTests {
    @Test
    func oldOAuthCredentialJSONDefaultsAccountIDToNil() throws {
        let credential = try JSONDecoder().decode(OAuthCredential.self, from: Data("""
        {"accessToken":"access","refreshToken":"refresh","expiresAt":0,"tokenType":"Bearer"}
        """.utf8))

        #expect(credential.accountID == nil)
    }

    @Test
    func codexUsageParsesSecondsResetAndKnownWindowKinds() throws {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("""
        {
          "rate_limit": {
            "primary_window": {"used_percent":125,"limit_window_seconds":18000,"reset_at":2000000000},
            "secondary_window": {"used_percent":20,"limit_window_seconds":604800,"reset_after_seconds":120}
          }
        }
        """.utf8))
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = try CodexUsageProvider.parseUsage(response, subscription: Subscription(providerID: .codex, name: "Codex", authMethodID: .codexDeviceOAuth), now: now)

        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.quotas.map(\.used) == [100, 20])
        #expect(snapshot.quotas[0].resetAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(snapshot.quotas[1].resetAt == now.addingTimeInterval(120))
    }

    @Test
    func codexUsageParsesMillisecondsResetAndGenericDuration() throws {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("""
        {"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":21600,"reset_at":2000000000000}}}
        """.utf8))
        let snapshot = try CodexUsageProvider.parseUsage(response, subscription: Subscription(providerID: .codex, name: "Codex", authMethodID: .codexDeviceOAuth))

        #expect(snapshot.quotas.count == 1)
        #expect(snapshot.quotas[0].kind == .generic)
        #expect(snapshot.quotas[0].name == "6 小时额度")
        #expect(snapshot.quotas[0].resetAt == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test
    func codexUsageParsingRejectsEmptyWindows() throws {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(#"{"rate_limit":{}}"#.utf8))
        #expect {
            _ = try CodexUsageProvider.parseUsage(
                response,
                subscription: Subscription(providerID: .codex, name: "Codex", authMethodID: .codexDeviceOAuth)
            )
        } throws: { error in
            guard case let UsageProviderError.invalidResponse(providerID, message) = error else { return false }
            return providerID == .codex && message == "Codex 返回中没有可解析的额度窗口"
        }
    }

    private func makeCodexJWT(payload: String) -> String {
        let encoded = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    @Test
    func codexOAuthAccountIDReadsNestedAuthClaim() {
        let jwt = makeCodexJWT(payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"u-codex-123"}}"#)
        #expect(CodexOAuthService.accountID(fromJWT: jwt) == "u-codex-123")

        // 旧扁平键（带点拼接）不应被当作账户 ID。
        let flat = makeCodexJWT(payload: #"{"https://api.openai.com/auth.chatgpt_account_id":"u-flat"}"#)
        #expect(CodexOAuthService.accountID(fromJWT: flat) == nil)
    }

    @Test
    func codexOAuthAccountIDFallsBackToIDTokenAndPreservesFallback() {
        let access = makeCodexJWT(payload: #"{"sub":"no-account-claim"}"#)
        let idToken = makeCodexJWT(payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"u-from-id-token"}}"#)
        #expect(CodexOAuthService.accountID(accessToken: access, idToken: idToken, fallbackAccountID: nil) == "u-from-id-token")

        // 两个 token 都没有 claim 时，refresh 场景必须保留旧 accountID。
        #expect(CodexOAuthService.accountID(accessToken: access, idToken: nil, fallbackAccountID: "u-old") == "u-old")

        // access token 里的 claim 优先于 id_token 与旧值。
        let accessWithClaim = makeCodexJWT(payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"u-from-access"}}"#)
        #expect(CodexOAuthService.accountID(accessToken: accessWithClaim, idToken: idToken, fallbackAccountID: "u-old") == "u-from-access")
    }

    @Test
    func codexOAuthRefreshKeepsOldRefreshTokenWhenResponseOmitsIt() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let access = makeCodexJWT(payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"u-codex"}}"#)
        let data = Data("""
        {"access_token":"\(access)","expires_in":3600,"token_type":"Bearer"}
        """.utf8)

        let credential = try CodexOAuthService.credential(
            from: data,
            now: now,
            fallbackAccountID: "u-codex",
            fallbackRefreshToken: "old-refresh"
        )

        #expect(credential.refreshToken == "old-refresh")
        #expect(credential.accountID == "u-codex")
        #expect(credential.expiresAt == now.addingTimeInterval(3_600))
    }

    @Test
    func codexOAuthRefreshUsesNewRefreshTokenWhenReturned() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let access = makeCodexJWT(payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"u-codex"}}"#)
        let data = Data("""
        {"access_token":"\(access)","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}
        """.utf8)

        let credential = try CodexOAuthService.credential(
            from: data,
            now: now,
            fallbackAccountID: "u-codex",
            fallbackRefreshToken: "old-refresh"
        )

        #expect(credential.refreshToken == "new-refresh")
        #expect(credential.accountID == "u-codex")
        #expect(credential.expiresAt == now.addingTimeInterval(3_600))
    }

    @Test
    func codexOAuthCredentialRejectsMissingRefreshTokenWithoutFallback() {
        let access = makeCodexJWT(payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"u-codex"}}"#)
        let data = Data("""
        {"access_token":"\(access)","expires_in":3600,"token_type":"Bearer"}
        """.utf8)

        #expect {
            _ = try CodexOAuthService.credential(
                from: data,
                now: .now,
                fallbackAccountID: nil,
                fallbackRefreshToken: nil
            )
        } throws: { error in
            guard case CodexOAuthError.invalidResponse(let message) = error else { return false }
            return message == "令牌响应缺少必要字段"
        }
    }

    @Test
    func codexOAuthPollingRetriesPendingAndTransientFailures() {
        // OpenAI 设备码用 403/404 表示用户未完成授权（oh-my-pi 参考实现）；
        // 429/5xx 与网络/超时是瞬时故障。这些都必须继续轮询。
        for status in [403, 404, 429, 500, 503] {
            #expect(CodexOAuthService.continuePolling(after: CodexOAuthError.httpStatus(status)))
        }
        #expect(CodexOAuthService.continuePolling(after: CodexOAuthError.timedOut))
        #expect(CodexOAuthService.continuePolling(after: CodexOAuthError.networkFailed))

        // 其余错误（如 400、凭证失效、响应无法解析）不得被误当 pending。
        #expect(!CodexOAuthService.continuePolling(after: CodexOAuthError.httpStatus(400)))
        #expect(!CodexOAuthService.continuePolling(after: CodexOAuthError.authorizationRequired))
        #expect(!CodexOAuthService.continuePolling(after: CodexOAuthError.invalidResponse("x")))
    }

    // MARK: - 网络路径（注入传输层）

    private func makeTemporaryCredentialStore() -> (CredentialStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterCodexTests-\(UUID().uuidString)")
            .appendingPathComponent("credentials.json")
        return (CredentialStore(fileURL: url), url)
    }

    /// 注入桩传输层，使真实的 fetchUsage 状态机在无网络的情况下被驱动。
    private func makeStubbedProvider(
        stub: HTTPStub,
        store: CredentialStore,
        subscriptionID: UUID
    ) async -> CodexUsageProvider {
        let transport = await stub.transport
        return CodexUsageProvider(
            subscription: Subscription(id: subscriptionID, providerID: .codex, name: "Codex", authMethodID: .codexDeviceOAuth),
            credentials: store,
            oauthService: CodexOAuthService(transport: transport),
            transport: transport
        )
    }

    private func storeStaleCredential(_ store: CredentialStore, _ subscriptionID: UUID) throws {
        try store.save(oauthCredential: OAuthCredential(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: .distantFuture,
            tokenType: "Bearer",
            accountID: "u-codex"
        ), for: subscriptionID)
    }

    private func makeTokenResponseBody() -> Data {
        let jwt = makeCodexJWT(payload: #"{"https://api.openai.com/auth":{"chatgpt_account_id":"u-codex"}}"#)
        return Data("{\"access_token\":\"\(jwt)\",\"refresh_token\":\"refresh-2\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8)
    }

    @Test
    func codexUsageRefreshesOnceAfterUnauthorizedAndRetries() async throws {
        let (store, url) = makeTemporaryCredentialStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subscriptionID = UUID()
        try storeStaleCredential(store, subscriptionID)

        let tokenBody = makeTokenResponseBody()
        let stub = HTTPStub { path, index in
            switch path {
            case "/backend-api/wham/usage":
                guard index > 0 else { return (401, Data()) }
                return (200, Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}"#.utf8))
            case "/oauth/token":
                return (200, tokenBody)
            default:
                return (404, Data())
            }
        }

        let provider = await makeStubbedProvider(stub: stub, store: store, subscriptionID: subscriptionID)
        let snapshot = try await provider.fetchUsage()

        #expect(snapshot.quotas.map(\.kind) == [.fiveHour])
        let usageCalls = await stub.callCount(path: "/backend-api/wham/usage")
        let tokenCalls = await stub.callCount(path: "/oauth/token")
        #expect(usageCalls == 2)
        #expect(tokenCalls == 1)
        #expect(store.oauthCredential(for: subscriptionID)?.refreshToken == "refresh-2")
    }

    @Test
    func codexUsageStopsAfterOneRefreshWhenStillUnauthorized() async throws {
        let (store, url) = makeTemporaryCredentialStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let subscriptionID = UUID()
        try storeStaleCredential(store, subscriptionID)
        let tokenBody = makeTokenResponseBody()

        // 刷新后仍 401：必须只刷新一次并以认证失效结束，不得无限重试。
        let stub = HTTPStub { path, _ in
            switch path {
            case "/backend-api/wham/usage":
                return (401, Data())
            case "/oauth/token":
                return (200, tokenBody)
            default:
                return (404, Data())
            }
        }

        let provider = await makeStubbedProvider(stub: stub, store: store, subscriptionID: subscriptionID)
        do {
            _ = try await provider.fetchUsage()
            Issue.record("应当以认证失效结束")
        } catch let error as UsageProviderError {
            guard case .authenticationRequired = error else {
                Issue.record("错误的分类：\(error)")
                return
            }
        }

        let usageCalls = await stub.callCount(path: "/backend-api/wham/usage")
        let tokenCalls = await stub.callCount(path: "/oauth/token")
        #expect(usageCalls == 2)
        #expect(tokenCalls == 1)
    }

    @Test
    func codexOAuthAuthorizationPollsPendingUntilDeadline() async throws {
        // interval 1s / expires_in 2s：至少轮询一次 pending，然后按截止时间超时。
        let stub = HTTPStub { path, _ in
            switch path {
            case "/api/accounts/deviceauth/usercode":
                return (200, Data(#"{"device_auth_id":"device-1","user_code":"ABCD-1234","interval":1,"expires_in":2}"#.utf8))
            case "/api/accounts/deviceauth/token":
                return (403, Data())
            default:
                return (404, Data())
            }
        }
        let service = CodexOAuthService(transport: await stub.transport)

        do {
            _ = try await service.authorize()
            Issue.record("应当以超时结束")
        } catch CodexOAuthError.timedOut {
            // 预期
        }

        let pendingPolls = await stub.callCount(path: "/api/accounts/deviceauth/token")
        #expect(pendingPolls >= 1)
    }
}

/// 按 URL path 返回脚本化响应的传输桩，并记录每个 path 的调用次数。
private actor HTTPStub {
    private var counts: [String: Int] = [:]
    private let handler: @Sendable (String, Int) -> (Int, Data)

    init(handler: @escaping @Sendable (String, Int) -> (Int, Data)) {
        self.handler = handler
    }

    var transport: HTTPTransport {
        HTTPTransport { request in
            let (status, body) = await self.respond(path: request.url?.path ?? "")
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (body, response)
        }
    }

    func callCount(path: String) -> Int { counts[path] ?? 0 }

    private func respond(path: String) -> (Int, Data) {
        let index = counts[path, default: 0]
        counts[path] = index + 1
        return handler(path, index)
    }
}
