import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let openCodeGo = ProviderID(rawValue: "opencode-go")
}

// MARK: - 定义

struct OpenCodeGoProviderDefinition: ProviderDefinition {
    let id = ProviderID.openCodeGo

    /// 旧 `Platform` 枚举里的名字。
    var legacyPlatformNames: [String] { ["OpenCode Go"] }

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "OpenCode Go",
            iconResourceName: "icon-opencodego",
            fallbackSystemImage: "chevron.left.forwardslash.chevron.right",
            tintRGB: 0x32D74B,
            railMarkResource: "opencode",
            capabilityDescription: "支持用量窗口接口，可使用 API Key。",
            authPageURL: URL(string: "https://opencode.ai/zen"),
            homepageURL: URL(string: "https://opencode.ai"),
            authenticationSummary: "API Key · 支持用量窗口接口"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台")]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { OpenCodeGoCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        OpenCodeGoUsageProvider(subscription: subscription)
    }

}

// MARK: - 用量提供者

struct OpenCodeGoUsageProvider: UsageProvider {
    /// 用量窗口：接口字段别名 → 额度行显示名 + 紧凑卡短标签。
    /// 一处定义，解析侧与卡片侧不再各写一份窗口字符串。
    enum UsageWindow: String, CaseIterable {
        case rolling
        case weekly
        case monthly

        /// 接口里该窗口的字段名，按命中优先级排列。
        var aliases: [String] {
            switch self {
            case .rolling: ["rolling", "5h", "5_hour", "five_hour", "five_hours", "fivehour"]
            case .weekly: ["weekly", "week"]
            case .monthly: ["monthly", "month"]
            }
        }

        /// 额度行显示名（标准卡片与顶部锚点用）。
        var quotaName: String {
            switch self {
            case .rolling: "5 小时窗口"
            case .weekly: "每周窗口"
            case .monthly: "每月窗口"
            }
        }

        /// 紧凑卡数据行的短标签：与标准卡片的三个窗口一一对应。
        var compactLabel: String {
            switch self {
            case .rolling: "5h"
            case .weekly: "周"
            case .monthly: "月"
            }
        }
    }

    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let response: JSONValue = try await APIClient.get(
            URL(string: "https://opencode.ai/zen/go/v1/usage")!,
            providerID: subscription.providerID,
            authorization: "Bearer \(key)"
        )
        let windows = UsageWindow.allCases.compactMap { window -> Quota? in
            guard let value = response.findObject(for: window.aliases) else { return nil }
            return try? Self.quota(fromWindow: window.quotaName, object: value)
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "OpenCode Go 返回中未找到可可靠解析的用量窗口")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: windows)
    }

    private static func quota(fromWindow name: String, object: JSONValue) throws -> Quota {
        if let percent = object.number(for: ["percent", "percentage", "usage_percent", "usagePercentage"]),
           percent >= 0, percent <= 100 {
            return Quota(name: name, used: percent, limit: 100, resetAt: object.resetDate)
        }
        guard let used = object.number(for: ["used", "usage", "consumed", "used_tokens"]),
              let limit = object.number(for: ["limit", "max", "maximum", "total", "allowance"]),
              used >= 0, limit > 0 else {
            throw UsageProviderError.invalidResponse(.openCodeGo, "OpenCode Go 用量窗口缺少 percent 或 used/limit")
        }
        return Quota(name: name, used: used, limit: limit, resetAt: object.resetDate)
    }
}
