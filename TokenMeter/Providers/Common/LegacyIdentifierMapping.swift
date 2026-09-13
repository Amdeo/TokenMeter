import Foundation

// MARK: - 历史标识映射

/// 旧数据里的标识 → 稳定 ID。
///
/// 供应商专有的旧值写在各自的定义里（`legacyPlatformNames` / `legacyIDs`），
/// 共享层因此不需要维护供应商名单；新供应商不必声明任何东西。
extension ProviderID {
    /// 兼容旧 `Platform` 枚举的原始值（例如 "Kimi"）。
    static func legacyPlatformMapping(_ rawValue: String) -> ProviderID {
        ProviderRegistry.all.first { $0.legacyPlatformNames.contains(rawValue) }?.id
            ?? ProviderID(rawValue: rawValue)
    }
}

extension AuthMethodID {
    /// 兼容旧认证枚举值。三种通用写法与供应商无关，直接归到 api-key；
    /// 供应商专有的旧值由 `AuthMethodDefinition.legacyIDs` 声明。
    static func legacyMapping(_ rawValue: String) -> AuthMethodID {
        switch rawValue {
        case "manualAPIKey", "piAuth", "officialAuth": return .apiKey
        default: break
        }
        return ProviderRegistry.all
            .flatMap(\.authMethods)
            .first { $0.legacyIDs.contains(rawValue) }?.id
            ?? AuthMethodID(rawValue: rawValue)
    }
}
