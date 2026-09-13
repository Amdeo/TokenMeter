import Foundation

// MARK: - 认证机制分派

/// 设备授权（RFC 8628，用户码 + 浏览器确认）的已知实现。
/// 供应商只在自己的定义里声明用哪一个；引入全新协议时才需要在这里加一个 case。
enum DeviceAuthorizationKind: Sendable {
    case kimiCode
    case codexCode
}

/// 授权码（PKCE，粘贴回调地址换取令牌）的已知实现。
enum AuthorizationCodeKind: Sendable {
    case claudePKCE
}

/// 授权码流程所需的一次性 PKCE 参数与授权地址。
struct AuthorizationCodeRequest: Sendable {
    let url: URL
    let verifier: String
    let state: String
}

/// 设备授权分派：共享代码不认识供应商，只认识机制。
@MainActor
enum DeviceAuthorizationServices {
    static func authorize(
        kind: DeviceAuthorizationKind,
        onDeviceAuthorization: @escaping @Sendable (DeviceOAuthAuthorization) async -> Void
    ) async throws -> OAuthCredential {
        switch kind {
        case .kimiCode:
            try await KimiOAuthService().authorize(onDeviceAuthorization: onDeviceAuthorization)
        case .codexCode:
            try await CodexOAuthService().authorize(onDeviceAuthorization: onDeviceAuthorization)
        }
    }
}

/// 授权码（PKCE）分派。
@MainActor
enum AuthorizationCodeServices {
    /// 生成一次性 PKCE 与授权页地址；重复调用会作废上一次未兑换的授权。
    static func begin(kind: AuthorizationCodeKind) -> AuthorizationCodeRequest {
        switch kind {
        case .claudePKCE:
            let pkce = ClaudeOAuthService.makePKCE()
            return AuthorizationCodeRequest(
                url: ClaudeOAuthService.authorizationURL(pkce: pkce),
                verifier: pkce.verifier,
                state: pkce.state
            )
        }
    }

    /// 用用户粘贴的授权码/回调地址换取令牌。
    static func complete(
        kind: AuthorizationCodeKind,
        pastedText: String,
        verifier: String,
        state: String
    ) async throws -> OAuthCredential {
        switch kind {
        case .claudePKCE:
            try await ClaudeOAuthService().completeAuthorization(
                pastedText: pastedText,
                verifier: verifier,
                state: state
            )
        }
    }
}
