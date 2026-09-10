import Foundation

struct DeviceOAuthAuthorization: Sendable {
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
}

enum DeviceOAuthService {
    static func authorize(
        providerID: ProviderID,
        authMethodID: AuthMethodID,
        onDeviceAuthorization: @escaping @Sendable (DeviceOAuthAuthorization) async -> Void
    ) async throws -> OAuthCredential {
        switch (providerID, authMethodID) {
        case (.kimi, .kimiDeviceOAuth):
            return try await KimiOAuthService().authorize(onDeviceAuthorization: onDeviceAuthorization)
        case (.codex, .codexDeviceOAuth):
            return try await CodexOAuthService().authorize(onDeviceAuthorization: onDeviceAuthorization)
        default:
            throw UsageProviderError.notConfigured(providerID)
        }
    }
}
