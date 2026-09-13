import CryptoKit
import Foundation

/// Claude Code 的线上指纹常量。Claude 的 OAuth 与额度端点都按 CLI 指纹校验，
/// 因此这些值需与当前 Claude Code 发布保持一致（参考 oh-my-pi 的同名常量）。
enum ClaudeCodeFingerprint {
    static let version = "2.1.257"
    static let sdkVersion = "0.112.1"
    static let cliUserAgent = "claude-cli/\(version) (external, cli)"
    static let oauthUserAgent = "anthropic-sdk-typescript/\(sdkVersion) userOAuthProvider"
    static let oauthBeta = "oauth-2025-04-20"
    /// 额度端点随 CLI 一起发送的 beta 头集合。
    static let usageBeta = [
        "claude-code-20250219", "oauth-2025-04-20", "interleaved-thinking-2025-05-14",
        "redact-thinking-2026-02-12", "context-management-2025-06-27",
        "prompt-caching-scope-2026-01-05", "mid-conversation-system-2026-04-07",
        "advanced-tool-use-2025-11-20", "effort-2025-11-24", "extended-cache-ttl-2025-04-11"
    ].joined(separator: ",")
}

enum ClaudeOAuthError: LocalizedError, Sendable {
    case networkFailed
    case timedOut
    case authorizationRequired
    case invalidResponse(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .networkFailed: "Claude OAuth 网络暂时不可用，请检查网络后重试"
        case .timedOut: "Claude OAuth 请求超时，请重试"
        case .authorizationRequired: "Claude OAuth 凭证已失效，请重新授权"
        case .invalidResponse(let message): "Claude OAuth 响应无效：\(message)"
        case .httpStatus(let status): "Claude OAuth 返回 HTTP \(status)"
        }
    }
}

/// 授权码流程的一次性 PKCE 参数：生成授权链接后必须保留到兑换令牌为止。
struct ClaudePKCE: Sendable, Equatable {
    let verifier: String
    let challenge: String
    let state: String
}

/// Claude Pro/Max 的 claude.ai 授权码（PKCE）登录。
/// 端点、参数与请求头参考 oh-my-pi 的 `catalog/src/compat/rules/auth/anthropic.kdl`。
///
/// TokenMeter 不监听回调端口：授权页跳转到 `http://localhost:54545/callback` 时浏览器会
/// 报错，但地址栏里保留了 `code` 与 `state`，用户把它粘贴回来即可完成兑换。
struct ClaudeOAuthService: Sendable {
    /// Claude Code 的公开 OAuth 客户端 ID。
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// 必须是 Anthropic 白名单内的回调地址；TokenMeter 只借用它作为 `redirect_uri`。
    static let redirectURI = "http://localhost:54545/callback"
    static let scopes = [
        "org:create_api_key", "user:profile", "user:inference",
        "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"
    ]
    /// 额度端点按 Claude Code CLI 指纹校验，UA 与 beta 头需与 CLI 保持一致。
    static let cliVersion = ClaudeCodeFingerprint.version
    static let sdkVersion = ClaudeCodeFingerprint.sdkVersion
    static let cliUserAgent = ClaudeCodeFingerprint.cliUserAgent
    static let oauthUserAgent = ClaudeCodeFingerprint.oauthUserAgent
    static let oauthBeta = ClaudeCodeFingerprint.oauthBeta

    private static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenEndpoint = URL(string: "https://api.anthropic.com/v1/oauth/token")!

    var transport: HTTPTransport = .live

    // MARK: - 授权链接

    static func makePKCE() -> ClaudePKCE {
        let verifier = base64URL(randomBytes(32))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return ClaudePKCE(verifier: verifier, challenge: challenge, state: base64URL(randomBytes(16)))
    }

    static func authorizationURL(pkce: ClaudePKCE) -> URL {
        guard var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false) else {
            return authorizeEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code", value: "true")
        ]
        return components.url ?? authorizeEndpoint
    }

    /// 解析用户粘贴的内容：完整回调地址、`code#state`，或裸授权码。
    static func parseAuthorizationInput(_ raw: String, fallbackState: String) -> (code: String, state: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
            return (code, state.isEmpty ? fallbackState : state)
        }

        if let separator = trimmed.firstIndex(of: "#") {
            let code = String(trimmed[trimmed.startIndex..<separator])
            let state = String(trimmed[trimmed.index(after: separator)...])
            guard !code.isEmpty else { return nil }
            return (code, state.isEmpty ? fallbackState : state)
        }

        return (trimmed, fallbackState)
    }

    // MARK: - 令牌

    func completeAuthorization(
        pastedText: String,
        verifier: String,
        state: String,
        now: Date = .now
    ) async throws -> OAuthCredential {
        guard let parsed = Self.parseAuthorizationInput(pastedText, fallbackState: state) else {
            throw ClaudeOAuthError.invalidResponse("请粘贴授权码或回调地址")
        }
        let data = try await postJSON(Self.tokenEndpoint, body: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": parsed.code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
            "state": parsed.state
        ], headers: [:])
        return try Self.credential(from: data, now: now, fallbackAccountID: nil, fallbackRefreshToken: nil)
    }

    func refresh(_ credential: OAuthCredential, now: Date = .now) async throws -> OAuthCredential {
        // Claude Code 只在刷新时发送这两个头。
        let data = try await postJSON(Self.tokenEndpoint, body: [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": credential.refreshToken
        ], headers: [
            "anthropic-beta": Self.oauthBeta,
            "User-Agent": Self.oauthUserAgent
        ])
        return try Self.credential(
            from: data,
            now: now,
            fallbackAccountID: credential.accountID,
            fallbackRefreshToken: credential.refreshToken
        )
    }

    /// 解析令牌响应。刷新响应可能省略 `refresh_token` 与账户信息，此时沿用旧值。
    static func credential(
        from data: Data,
        now: Date,
        fallbackAccountID: String?,
        fallbackRefreshToken: String?
    ) throws -> OAuthCredential {
        do {
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            let accessToken = response.accessToken.trimmed
            guard !accessToken.isEmpty, response.expiresIn > 0 else {
                throw ClaudeOAuthError.invalidResponse("令牌响应缺少必要字段")
            }
            let responseRefreshToken = response.refreshToken?.trimmed ?? ""
            let refreshToken = responseRefreshToken.isEmpty ? fallbackRefreshToken?.trimmed : responseRefreshToken
            guard let refreshToken, !refreshToken.isEmpty else {
                throw ClaudeOAuthError.invalidResponse("令牌响应缺少 refresh_token")
            }
            // 账户 UUID 只用于展示；额度请求只需要 access token，缺失不视为失败。
            let responseAccountID = response.account?.uuid?.trimmed ?? ""
            let accountID = responseAccountID.isEmpty ? fallbackAccountID?.trimmed : responseAccountID
            return OAuthCredential(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn)),
                tokenType: "Bearer",
                accountID: (accountID?.isEmpty == false) ? accountID : nil
            )
        } catch let error as ClaudeOAuthError {
            throw error
        } catch {
            throw ClaudeOAuthError.invalidResponse("令牌响应无法解析")
        }
    }

    // MARK: - 传输

    private func postJSON(_ url: URL, body: [String: String], headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw ClaudeOAuthError.httpStatus(response.statusCode)
            }
            return data
        } catch let error as ClaudeOAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ClaudeOAuthError.timedOut
        } catch {
            throw ClaudeOAuthError.networkFailed
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct TokenResponse: Decodable {
        struct Account: Decodable {
            let uuid: String?
        }

        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let account: Account?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case account
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - 授权实现句柄

extension AuthorizationCodeHandler {
    /// Claude 授权码（PKCE）：浏览器授权后把整段回调地址粘回来。
    static let claudePKCE = AuthorizationCodeHandler(
        begin: {
            let pkce = ClaudeOAuthService.makePKCE()
            return AuthorizationCodeRequest(
                url: ClaudeOAuthService.authorizationURL(pkce: pkce),
                verifier: pkce.verifier,
                state: pkce.state
            )
        },
        complete: { pastedText, verifier, state in
            try await ClaudeOAuthService().completeAuthorization(
                pastedText: pastedText,
                verifier: verifier,
                state: state
            )
        }
    )
}
