import Foundation
import Testing
@testable import TokenMeter

// MARK: - JWT 载荷解码

/// `JWT` 是登录态提取器/续期器与 Codex 账户 ID 提取共用的唯一解码路径，
/// 这些用例锁定它从各处重复实现收敛后保持的边界行为。
struct JWTTests {
    private func makeToken(payload: String) -> String {
        let body = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(body).signature"
    }

    @Test
    func jwtExpirationReadsNumericExp() {
        let token = makeToken(payload: #"{"exp":1799999999}"#)
        #expect(JWT.expiration(of: token) == Date(timeIntervalSince1970: 1_799_999_999))
    }

    @Test
    func jwtExpirationTreatsStringExpAsUnavailable() {
        // 字符串形态的 exp 原先就被各实现拒绝，收敛后必须继续拒绝（否则无效令牌会被当作有效）。
        let token = makeToken(payload: #"{"exp":"1799999999"}"#)
        #expect(JWT.expiration(of: token) == nil)
    }

    @Test
    func jwtExpirationRejectsMalformedTokens() {
        // 段数不足、非 JSON 载荷、非法 base64url、为空都必须返回 nil。
        #expect(JWT.expiration(of: "header.signature") == nil)
        #expect(JWT.expiration(of: makeToken(payload: "not json")) == nil)
        #expect(JWT.expiration(of: "header.!!!not-base64!!!.signature") == nil)
        #expect(JWT.expiration(of: "") == nil)
        // 载荷里没有 exp。
        #expect(JWT.expiration(of: makeToken(payload: #"{"sub":"x"}"#)) == nil)
    }

    @Test
    func jwtPayloadRejectsNonObjectTopLevel() throws {
        #expect(JWT.payload(of: makeToken(payload: "[1,2,3]")) == nil)
        #expect(JWT.payload(of: makeToken(payload: "\"text\"")) == nil)
        #expect(try JWT.payload(of: makeToken(payload: #"{"sub":"x"}"#)) == JSONValue.object(["sub": .string("x")]))
    }

    @Test
    func jwtPayloadDecodesBase64URLAlphabet() {
        // 载荷里带非 ASCII 与需要 base64url 字母表的字节，确保替换与补齐逻辑正确。
        let payload = #"{"name":"页面登录态·Kimi"}"#
        let token = makeToken(payload: payload)
        guard case .string(let name)? = JWT.payload(of: token)?.value(for: ["name"]) else {
            Issue.record("应当解出 name")
            return
        }
        #expect(name == "页面登录态·Kimi")
    }
}

// MARK: - 内嵌登录窗口

/// 四个供应商原先各有一份逐行相同的登录控制器，现已收敛为
/// `EmbeddedWebLoginController` + 配置。这些用例锁定合并后各供应商的域名，
/// 以及「主域 + 子域」匹配语义（登录窗口何时允许尝试提取登录态）。
struct EmbeddedWebLoginControllerTests {
    @Test
    func loginControllerMatchesDomainAndSubdomains() {
        let domains = ["kimi.com"]
        #expect(EmbeddedWebLoginController.matches(host: "kimi.com", domains: domains))
        #expect(EmbeddedWebLoginController.matches(host: "www.kimi.com", domains: domains))
        #expect(EmbeddedWebLoginController.matches(host: "KIMI.COM", domains: domains))
        #expect(!EmbeddedWebLoginController.matches(host: "notkimi.com", domains: domains))
        // 不能把后缀包含主域的无关域名当成目标域。
        #expect(!EmbeddedWebLoginController.matches(host: "kimi.com.evil.com", domains: domains))
        #expect(!EmbeddedWebLoginController.matches(host: "kimi.com", domains: ["ccbus.top"]))
    }

    @Test
    func loginRecipesKeepProviderDomains() {
        #expect(BrowserLoginRecipe.kimi.sessionDomains == ["kimi.com"])
        #expect(BrowserLoginRecipe.ccbus.sessionDomains == ["ccbus.top"])
        #expect(BrowserLoginRecipe.apiKeyFun.sessionDomains == ["apikey.fun"])
        #expect(BrowserLoginRecipe.nowCoding.sessionDomains == ["nowcoding.ai"])
    }

    @Test
    @MainActor
    func loginControllerExposesSessionDomainsForSiteDataClearing() {
        // 切换账号时靠这个属性清除对应域的站点数据，必须与配方一致。
        let controller = EmbeddedWebLoginController(configuration: .browserLogin(.ccbus))
        #expect(controller.sessionDomains == ["ccbus.top"])
    }
}

// MARK: - 网页登录态续期

/// 合并前续期流程只有「响应模型可解码」这一条测试（请求路径没有注入缝隙）。
/// 这里用 HTTPStub 真正跑通请求路径，并把各供应商的错误映射也钐住。
struct BrowserSessionRefresherTests {
    private static let apiBase = URL(string: "https://example.test/api/v1")!
    private static let successBody = Data(
        #"{"code":0,"message":"success","data":{"access_token":"new-access","refresh_token":"new-refresh","expires_in":7200}}"#.utf8
    )

    private static func credential() -> KimiBrowserCredential {
        KimiBrowserCredential(
            accessToken: "old-access", refreshToken: "old-refresh", expiresAt: .now, tokenType: "Bearer"
        )
    }

    private static func makeJWT(exp: Int) -> String {
        let body = Data(#"{"exp":\#(exp)}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(body).signature"
    }

    /// 断言续期以指定的语义失败结束。
    private func expectFailure(
        _ body: Data,
        status: Int = 200,
        matches expected: BrowserSessionRefresher.Failure
    ) async {
        let stub = HTTPStub { _, _ in (status, body) }
        let transport = await stub.transport
        do {
            _ = try await BrowserSessionRefresher.refresh(
                Self.credential(), apiBase: Self.apiBase, transport: transport
            )
            Issue.record("应当以 \(expected) 结束")
        } catch let failure as BrowserSessionRefresher.Failure {
            #expect(failure == expected)
        } catch {
            Issue.record("错误的分类：\(error)")
        }
    }

    @Test
    func refresherExchangesRefreshTokenAgainstAPIBase() async throws {
        let stub = HTTPStub { _, _ in (200, Self.successBody) }
        let transport = await stub.transport
        let before = Date.now

        let credential = try await BrowserSessionRefresher.refresh(
            Self.credential(), apiBase: Self.apiBase, transport: transport
        )

        #expect(credential.accessToken == "new-access")
        #expect(credential.refreshToken == "new-refresh")
        #expect(credential.tokenType == "Bearer")
        #expect(credential.expiresAt.timeIntervalSince(before) >= 7_000)
        // 请求落在 {apiBase}/auth/refresh。
        #expect(await stub.callCount(path: "/api/v1/auth/refresh") == 1)
    }

    @Test
    func refresherTreatsRejectedRefreshTokenAsInvalidCredentials() async {
        // 400/401/403 才是「登录态真失效」；这类才应该提示重新登录。
        for status in [400, 401, 403] {
            await expectFailure(Data(), status: status, matches: .invalidCredentials)
        }
    }

    @Test
    func refresherTreatsServerAndRateLimitFailuresAsTemporary() async {
        // 5xx/429 不能判成需要重新登录，否则用户会被误导去重登。
        await expectFailure(Data(), status: 503, matches: .requestFailed("HTTP 503"))
        await expectFailure(Data(), status: 429, matches: .requestFailed("HTTP 429"))
    }

    @Test
    func refresherRejectsUnusableResponseBodies() async {
        // code 非 0、token 为空、响应不是 JSON 都归为登录态不可用。
        await expectFailure(Data(#"{"code":1,"message":"expired"}"#.utf8), matches: .invalidCredentials)
        await expectFailure(
            Data(#"{"code":0,"data":{"access_token":"  ","refresh_token":"r"}}"#.utf8),
            matches: .invalidCredentials
        )
        await expectFailure(Data("not json".utf8), matches: .invalidCredentials)
    }

    @Test
    func refresherFallsBackToJWTExpiryWhenExpiresInIsMissing() async throws {
        let exp = Int(Date.now.addingTimeInterval(3_600).timeIntervalSince1970)
        let token = Self.makeJWT(exp: exp)
        let body = Data(#"{"code":0,"data":{"access_token":"\#(token)","refresh_token":"r"}}"#.utf8)
        let stub = HTTPStub { _, _ in (200, body) }
        let transport = await stub.transport

        let credential = try await BrowserSessionRefresher.refresh(
            Self.credential(), apiBase: Self.apiBase, transport: transport
        )

        #expect(credential.expiresAt.timeIntervalSince1970 == Double(exp))
    }

    @Test
    func refresherRejectsOpaqueTokenWithoutExpiry() async {
        // 既无 expires_in、token 也不是带 exp 的 JWT：无法确定有效期，视为不可用。
        await expectFailure(
            Data(#"{"code":0,"data":{"access_token":"opaque","refresh_token":"r"}}"#.utf8),
            matches: .invalidCredentials
        )
    }

    @Test
    func providerRefreshersMapSemanticFailuresToTheirOwnErrors() async {
        // 映射不能搞错：401 必须变成 expired（isInvalid 依赖它判定需要重登），
        // 且错误要带上本供应商的名字，否则用户会看到别家的提示。
        let unauthorized = HTTPStub { _, _ in (401, Data()) }
        let unauthorizedTransport = await unauthorized.transport
        do {
            _ = try await BrowserRelayRefresher.apiKeyFun.refresh(
                Self.credential(), transport: unauthorizedTransport
            )
            Issue.record("应以 APIKEY.FUN 登录态失效结束")
        } catch BrowserLoginError.expired(let provider) {
            #expect(provider == "APIKEY.FUN")
        } catch {
            Issue.record("错误的分类：\(error)")
        }

        let outage = HTTPStub { _, _ in (500, Data()) }
        let outageTransport = await outage.transport
        do {
            _ = try await BrowserRelayRefresher.ccbus.refresh(Self.credential(), transport: outageTransport)
            Issue.record("应以 CCBus 续期失败结束")
        } catch BrowserLoginError.refreshFailed(let provider, let message) {
            #expect(provider == "CCBus")
            #expect(message == "HTTP 500")
        } catch {
            Issue.record("错误的分类：\(error)")
        }
    }
}
