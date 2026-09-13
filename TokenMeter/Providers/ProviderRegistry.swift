import SwiftUI

// MARK: - 供应商注册表

/// 供应商注册表门面：目录来自 `ProviderCatalog`，查找结果全部由定义派生。
///
/// 这里不再硬编码任何供应商名单。`isSupported` 与 `authFlow` 都从
/// `ProviderDefinition` 自身声明的数据推导，因此新增供应商不可能漏改本文件——
/// 这正是把「共享代码不按供应商 switch」落成机制的那一步。
///
/// 故意保持非隔离：凭据迁移等非 UI 路径需要在不进入主 actor 的情况下完成这些查找。
enum ProviderRegistry {
    /// 唯一供应商目录；初始化时校验 ID 唯一性（Assert 保护，避免误注册重复 ID）。
    static let all: [any ProviderDefinition] = {
        let definitions = ProviderCatalog.providers
        var seen = Set<String>()
        for definition in definitions {
            assert(seen.insert(definition.id.rawValue).inserted, "重复的 ProviderID: \(definition.id.rawValue)")
        }
        return definitions
    }()

    static func definition(for providerID: ProviderID) -> (any ProviderDefinition)? {
        all.first { $0.id == providerID }
    }

    /// 是否已注册该供应商（凭据迁移据此判断能否导入）。
    static func isSupported(_ providerID: ProviderID) -> Bool {
        definition(for: providerID) != nil
    }

    /// 认证方式对应的认证流程；未注册的供应商或认证方式返回 nil。
    static func authFlow(for providerID: ProviderID, authMethodID: AuthMethodID) -> AuthFlowID? {
        definition(for: providerID)?.authMethods.first { $0.id == authMethodID }?.flowID
    }

    /// 该供应商声明的默认认证方式（编辑页新建订阅时的初始选择）。
    static func defaultAuthMethod(for providerID: ProviderID) -> AuthMethodID? {
        definition(for: providerID)?.authMethods.first?.id
    }
}

// MARK: - 未支持供应商

/// 未知/未注册供应商的降级定义：保留订阅但不崩溃，显示不可用状态。
struct UnsupportedProviderDefinition: ProviderDefinition {
    let id: ProviderID

    init(providerID: ProviderID) {
        self.id = providerID
    }

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: id.rawValue,
            iconResourceName: nil,
            fallbackSystemImage: "questionmark.circle",
            tintRGB: 0x737875,
            capabilityDescription: "未知供应商，暂无额度接口。",
            authPageURL: nil,
            authenticationSummary: "接口不支持"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "未知供应商")]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { UnsupportedCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        UnsupportedUsageProvider(subscription: subscription)
    }

}

/// 始终抛出 unsupported 的占位 provider（未知供应商刷新时不会崩溃）。
struct UnsupportedUsageProvider: UsageProvider {
    let subscription: Subscription

    func fetchUsage() async throws -> UsageSnapshot {
        throw UsageProviderError.unsupported(subscription.providerID)
    }
}
