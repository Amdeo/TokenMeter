import Foundation

enum CodexOAuthError: LocalizedError, Sendable {
    case networkFailed
    case timedOut
    case authorizationRequired
    case invalidResponse(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .networkFailed: "Codex OAuth 网络暂时不可用，请检查网络后重试"
        case .timedOut: "Codex OAuth 请求超时，请重试"
        case .authorizationRequired: "Codex OAuth 凭证已失效，请重新授权"
        case .invalidResponse(let message): "Codex OAuth 响应无效：\(message)"
        case .httpStatus(let status): "Codex OAuth 返回 HTTP \(status)"
        }
    }
}

struct CodexOAuthService: Sendable {
    var transport: HTTPTransport = .live

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let deviceAuthorizationURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    private static let deviceTokenURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    private static let redirectURI = "https://auth.openai.com/deviceauth/callback"

    func authorize(onDeviceAuthorization: @escaping @Sendable (DeviceOAuthAuthorization) async -> Void = { _ in }) async throws -> OAuthCredential {
        let device = try await requestDeviceAuthorization()
        let deadline = Date.now.addingTimeInterval(TimeInterval(device.expiresIn))
        await onDeviceAuthorization(DeviceOAuthAuthorization(
            userCode: device.userCode,
            verificationURL: Self.verificationURL,
            expiresAt: deadline
        ))

        while Date.now < deadline {
            try await Task.sleep(for: .seconds(Double(device.interval)))
            guard Date.now < deadline else { break }

            let code: AuthorizationCodeResponse
            do {
                code = try await requestAuthorizationCode(device: device)
            } catch {
                guard Self.continuePolling(after: error) else { throw error }
                continue
            }

            // 授权码已拿到，兑换失败不是 pending，直接抛出，避免继续轮询。
            return try await exchangeAuthorizationCode(code)
        }
        throw CodexOAuthError.timedOut
    }

    func refresh(_ existingCredential: OAuthCredential, now: Date = .now) async throws -> OAuthCredential {
        let response = try await formPost(Self.tokenURL, body: [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": existingCredential.refreshToken
        ])
        return try Self.credential(
            from: response,
            now: now,
            fallbackAccountID: existingCredential.accountID,
            fallbackRefreshToken: existingCredential.refreshToken
        )
    }

    private func requestDeviceAuthorization() async throws -> DeviceAuthorizationResponse {
        let data = try await jsonPost(Self.deviceAuthorizationURL, body: ["client_id": Self.clientID])
        do {
            let response = try JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data)
            guard !response.deviceAuthID.trimmed.isEmpty, !response.userCode.trimmed.isEmpty else {
                throw CodexOAuthError.invalidResponse("设备授权响应缺少必要字段")
            }
            return response
        } catch let error as CodexOAuthError {
            throw error
        } catch {
            throw CodexOAuthError.invalidResponse("设备授权响应无法解析")
        }
    }

    private func requestAuthorizationCode(device: DeviceAuthorizationResponse) async throws -> AuthorizationCodeResponse {
        let data = try await jsonPost(Self.deviceTokenURL, body: [
            "device_auth_id": device.deviceAuthID,
            "user_code": device.userCode
        ])
        do {
            let response = try JSONDecoder().decode(AuthorizationCodeResponse.self, from: data)
            guard !response.authorizationCode.trimmed.isEmpty, !response.codeVerifier.trimmed.isEmpty else {
                throw CodexOAuthError.invalidResponse("授权响应缺少必要字段")
            }
            return response
        } catch let error as CodexOAuthError {
            throw error
        } catch {
            throw CodexOAuthError.invalidResponse("授权响应无法解析")
        }
    }

    private func exchangeAuthorizationCode(_ code: AuthorizationCodeResponse) async throws -> OAuthCredential {
        let data = try await formPost(Self.tokenURL, body: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code.authorizationCode,
            "code_verifier": code.codeVerifier,
            "redirect_uri": Self.redirectURI
        ])
        return try Self.credential(from: data, now: .now, fallbackAccountID: nil, fallbackRefreshToken: nil)
    }

    static func credential(
        from data: Data,
        now: Date,
        fallbackAccountID: String?,
        fallbackRefreshToken: String?
    ) throws -> OAuthCredential {
        do {
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            // OpenAI refresh 可不轮换 refresh_token；仅在响应缺失或为空时回退旧值。
            let responseRefreshToken = response.refreshToken?.trimmed
            let refreshToken: String?
            if let responseRefreshToken, !responseRefreshToken.isEmpty {
                refreshToken = responseRefreshToken
            } else {
                refreshToken = fallbackRefreshToken?.trimmed
            }
            guard !response.accessToken.trimmed.isEmpty,
                  let resolvedRefreshToken = refreshToken,
                  !resolvedRefreshToken.isEmpty,
                  response.expiresIn > 0 else {
                throw CodexOAuthError.invalidResponse("令牌响应缺少必要字段")
            }
            let tokenType = response.tokenType?.trimmed.isEmpty == false ? response.tokenType!.trimmed : "Bearer"
            let accountID = Self.accountID(
                accessToken: response.accessToken,
                idToken: response.idToken,
                fallbackAccountID: fallbackAccountID
            )
            guard let accountID, !accountID.trimmed.isEmpty else {
                throw CodexOAuthError.authorizationRequired
            }
            return OAuthCredential(
                accessToken: response.accessToken,
                refreshToken: resolvedRefreshToken,
                expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn)),
                tokenType: tokenType,
                accountID: accountID
            )
        } catch let error as CodexOAuthError {
            throw error
        } catch {
            throw CodexOAuthError.invalidResponse("令牌响应无法解析")
        }
    }

    private func jsonPost(_ url: URL, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func formPost(_ url: URL, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }.sorted().joined(separator: "&").data(using: .utf8)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else { throw CodexOAuthError.httpStatus(response.statusCode) }
            return data
        } catch let error as CodexOAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw CodexOAuthError.timedOut
        } catch {
            throw CodexOAuthError.networkFailed
        }
    }

    /// 依次从 access token、id_token 中提取账户 ID，最后回退到已有凭证里的旧值。
    static func accountID(accessToken: String, idToken: String?, fallbackAccountID: String?) -> String? {
        accountID(fromJWT: accessToken)
            ?? idToken.flatMap { accountID(fromJWT: $0) }
            ?? fallbackAccountID
    }

    /// 读取 JWT payload 中的嵌套账户 ID claim：
    /// `payload["https://api.openai.com/auth"]["chatgpt_account_id"]`。
    static func accountID(fromJWT token: String) -> String? {
        guard case .object(let auth)? = JWT.payload(of: token)?.value(for: ["https://api.openai.com/auth"]),
              case .string(let accountID)? = auth["chatgpt_account_id"] else { return nil }
        return accountID
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 判断轮询失败是否应继续等待。403/404 是 OpenAI 设备码的「用户尚未完成授权」；
    /// 超时、断网、429 与服务端错误是瞬时故障，都值得继续轮询。其余错误立即抛出。
    static func continuePolling(after error: Error) -> Bool {
        switch error {
        case CodexOAuthError.timedOut, CodexOAuthError.networkFailed:
            true
        case CodexOAuthError.httpStatus(let status):
            status == 403 || status == 404 || status == 429 || status >= 500
        default:
            false
        }
    }

    private struct DeviceAuthorizationResponse: Decodable {
        let deviceAuthID: String
        let userCode: String
        let interval: Int
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
            case interval
            case expiresIn = "expires_in"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
            userCode = try container.decode(String.self, forKey: .userCode)
            interval = max(1, try container.decodeIfPresent(Int.self, forKey: .interval) ?? 5)
            expiresIn = max(1, try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 600)
        }
    }

    private struct AuthorizationCodeResponse: Decodable {
        let authorizationCode: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let tokenType: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case idToken = "id_token"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
