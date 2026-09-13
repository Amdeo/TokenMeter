import Foundation


enum KimiOAuthError: LocalizedError, Sendable {
    case requestFailed
    case httpStatus(Int)
    case invalidResponse(String)
    case authorizationPending
    case slowDown
    case authorizationDenied
    case authorizationExpired
    case unknownAuthorizationError
    case timedOut

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Kimi OAuth 请求失败，请检查网络后重试"
        case .httpStatus(let status): return "Kimi OAuth 返回 HTTP \(status)"
        case .invalidResponse(let message): return "Kimi OAuth 响应无效：\(message)"
        case .authorizationPending: return "Kimi OAuth 正在等待授权"
        case .slowDown: return "Kimi OAuth 请求过于频繁"
        case .authorizationDenied: return "Kimi OAuth 授权被拒绝"
        case .authorizationExpired: return "Kimi OAuth 授权已过期，请重试"
        case .unknownAuthorizationError: return "Kimi OAuth 返回了未知授权错误，请重试"
        case .timedOut: return "Kimi OAuth 授权等待超时，请重试"
        }
    }
}

struct KimiOAuthService: Sendable {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private static let host = URL(string: "https://auth.kimi.com")!
    private static let deviceEndpoint = host.appendingPathComponent("/api/oauth/device_authorization")
    private static let tokenEndpoint = host.appendingPathComponent("/api/oauth/token")

    func authorize(onDeviceAuthorization: @escaping @Sendable (DeviceOAuthAuthorization) async -> Void = { _ in }) async throws -> OAuthCredential {
        let hardDeadline = Date.now.addingTimeInterval(15 * 60)
        var device = try await requestDeviceAuthorization()
        // 以服务端 expires_in 为准：更早到期时不应继续轮询已失效的设备码。
        var deadline = min(hardDeadline, device.publicValue.expiresAt)
        await onDeviceAuthorization(device.publicValue)
        while true {
            try await wait(seconds: device.interval, until: deadline)
            guard Date.now < deadline else { throw KimiOAuthError.timedOut }
            do {
                return try await requestToken(grantType: "urn:ietf:params:oauth:grant-type:device_code", deviceCode: device.deviceCode)
            } catch KimiOAuthError.authorizationPending {
                continue
            } catch KimiOAuthError.slowDown {
                device.interval = min(device.interval + 5, 60)
            } catch KimiOAuthError.authorizationExpired {
                // 服务端已拒绝旧设备码：若仍在 15 分钟硬期限内，
                // 重新申请一个新的设备授权。
                guard Date.now < hardDeadline else { throw KimiOAuthError.timedOut }
                device = try await requestDeviceAuthorization()
                deadline = min(hardDeadline, device.publicValue.expiresAt)
                await onDeviceAuthorization(device.publicValue)
            } catch KimiOAuthError.authorizationDenied {
                throw KimiOAuthError.authorizationDenied
            } catch KimiOAuthError.unknownAuthorizationError {
                throw KimiOAuthError.unknownAuthorizationError
            }
        }
    }

    func refresh(_ credential: OAuthCredential, now: Date = .now) async throws -> OAuthCredential {
        try await requestToken(grantType: "refresh_token", refreshToken: credential.refreshToken, now: now)
    }

    private func requestDeviceAuthorization() async throws -> DeviceAuthorizationResponse {
        let data = try await post(Self.deviceEndpoint, body: ["client_id": Self.clientID])
        do {
            let response = try JSONDecoder().decode(DeviceAuthorizationResponse.self, from: data)
            guard !response.deviceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !response.userCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let verificationURL = URL(string: response.verificationURIComplete ?? response.verificationURI ?? ""),
                  let scheme = verificationURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  verificationURL.host != nil,
                  response.expiresIn > 0 else {
                throw KimiOAuthError.invalidResponse("设备授权响应缺少必要字段")
            }
            return response.with(verificationURL: verificationURL)
        } catch let error as KimiOAuthError {
            throw error
        } catch {
            throw KimiOAuthError.invalidResponse("设备授权响应无法解析")
        }
    }

    private func requestToken(grantType: String, deviceCode: String? = nil, refreshToken: String? = nil, now: Date = .now) async throws -> OAuthCredential {
        var body = ["client_id": Self.clientID, "grant_type": grantType]
        if let deviceCode { body["device_code"] = deviceCode }
        if let refreshToken { body["refresh_token"] = refreshToken }
        let data = try await post(Self.tokenEndpoint, body: body)
        do {
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard !response.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !response.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  response.expiresIn > 0 else {
                throw KimiOAuthError.invalidResponse("令牌响应缺少必要字段")
            }
            let tokenType = response.tokenType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Bearer"
            guard !tokenType.isEmpty else {
                throw KimiOAuthError.invalidResponse("令牌响应缺少必要字段")
            }
            return OAuthCredential(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn)),
                tokenType: tokenType
            )
        } catch let error as KimiOAuthError {
            throw error
        } catch {
            throw KimiOAuthError.invalidResponse("令牌响应无法解析")
        }
    }

    private func post(_ url: URL, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body.map { key, value in
            "\(Self.formEncode(key))=\(Self.formEncode(value))"
        }.sorted().joined(separator: "&").data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw KimiOAuthError.requestFailed
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw Self.oauthError(status: httpResponse.statusCode, data: data)
            }
            return data
        } catch let error as KimiOAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KimiOAuthError.requestFailed
        }
    }

    private func wait(seconds: Int, until deadline: Date) async throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw KimiOAuthError.timedOut }
        try await Task.sleep(for: .seconds(min(Double(max(seconds, 1)), remaining)))
    }

    private static func oauthError(status: Int, data: Data) -> KimiOAuthError {
        guard let response = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
              let code = response.error?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else {
            return .httpStatus(status)
        }
        switch code {
        case "authorization_pending": return .authorizationPending
        case "slow_down": return .slowDown
        case "expired_token": return .authorizationExpired
        case "access_denied": return .authorizationDenied
        default: return .unknownAuthorizationError
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct DeviceAuthorizationResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURIComplete: String?
        let verificationURI: String?
        let expiresIn: Int
        var interval: Int
        var verificationURL: URL = URL(string: "about:blank")!

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceCode = try container.decode(String.self, forKey: .deviceCode)
            userCode = try container.decode(String.self, forKey: .userCode)
            verificationURIComplete = try container.decodeIfPresent(String.self, forKey: .verificationURIComplete)
            verificationURI = try container.decodeIfPresent(String.self, forKey: .verificationURI)
            expiresIn = try container.decode(Int.self, forKey: .expiresIn)
            interval = max(1, try container.decodeIfPresent(Int.self, forKey: .interval) ?? 5)
        }

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURIComplete = "verification_uri_complete"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }

        var publicValue: DeviceOAuthAuthorization {
            DeviceOAuthAuthorization(userCode: userCode, verificationURL: verificationURL, expiresAt: Date.now.addingTimeInterval(TimeInterval(expiresIn)))
        }

        func with(verificationURL: URL) -> DeviceAuthorizationResponse {
            var response = self
            response.verificationURL = verificationURL
            return response
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}

// MARK: - 授权实现句柄

extension DeviceAuthorizationHandler {
    /// Kimi Code 设备授权（RFC 8628）。
    static let kimiCode = DeviceAuthorizationHandler { onDeviceAuthorization in
        try await KimiOAuthService().authorize(onDeviceAuthorization: onDeviceAuthorization)
    }
}
