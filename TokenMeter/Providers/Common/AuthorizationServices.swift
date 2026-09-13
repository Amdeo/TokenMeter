import Foundation

// MARK: - 授权机制

/// 设备授权过程中把 userCode 交给 UI 的回调。
typealias DeviceAuthorizationCallback = @Sendable (DeviceOAuthAuthorization) async -> Void

/// 设备授权（RFC 8628，用户码 + 浏览器确认）的实现句柄。
///
/// 实现常量由供应商在自己目录里声明（`deviceAuthorization: .kimiCode`），
/// 共享层只认这个句柄，不认识任何供应商，也没有分派表。
struct DeviceAuthorizationHandler: Sendable {
    let authorize: @Sendable (_ onDeviceAuthorization: @escaping DeviceAuthorizationCallback) async throws -> OAuthCredential
}

/// 授权码（PKCE，粘贴回调地址换取令牌）的实现句柄。
struct AuthorizationCodeHandler: Sendable {
    /// 生成一次性 PKCE 与授权页地址；重复调用会作废上一次未兑换的授权。
    let begin: @Sendable () -> AuthorizationCodeRequest
    /// 用用户粘贴的授权码/回调地址换取令牌。
    let complete: @Sendable (_ pastedText: String, _ verifier: String, _ state: String) async throws -> OAuthCredential
}

/// 授权码流程所需的一次性 PKCE 参数与授权地址。
struct AuthorizationCodeRequest: Sendable {
    let url: URL
    let verifier: String
    let state: String
}
