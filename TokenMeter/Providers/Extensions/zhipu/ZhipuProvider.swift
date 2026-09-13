import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let zhipu = ProviderID(rawValue: "zhipu")
}

// MARK: - 定义

struct ZhipuProviderDefinition: ProviderDefinition {
    let id = ProviderID.zhipu

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "智谱 AI",
            iconResourceName: "icon-zhipu",
            fallbackSystemImage: "sparkles",
            tintRGB: 0xBF5AF2,
            capabilityDescription: "支持 GLM Coding Plan 额度窗口（5 小时 / 每周），仅支持 API Key；暂无公开 OAuth 集成。",
            authPageURL: URL(string: "https://www.bigmodel.cn/usercenter/proj-mgmt/apikeys"),
            homepageURL: URL(string: "https://www.bigmodel.cn"),
            authenticationSummary: "API Key · 支持 GLM Coding Plan 额度窗口"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台")]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { QuotaListCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        ZhipuUsageProvider(subscription: subscription)
    }

}

// MARK: - 用量提供者

struct ZhipuUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        // 大陆站 biz/monitor 网关只认裸 API key（无 Bearer 前缀）
        let root: JSONValue = try await APIClient.get(
            URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!,
            providerID: subscription.providerID,
            authorization: key
        )
        if let code = root.number(for: ["code"]), code != 200 {
            let message = root.string(for: ["message"]) ?? root.string(for: ["msg"]) ?? "未知错误"
            throw UsageProviderError.invalidResponse(subscription.providerID, "接口返回错误（code \(Int(code))：\(message)）")
        }
        let data = root.value(for: ["data"])
        let limits = data?.arrayValue ?? data?.value(for: ["limits"])?.arrayValue ?? []
        var quotas: [Quota] = []
        for item in limits {
            let type = item.string(for: ["type"]) ?? item.string(for: ["name"]) ?? ""
            guard type == "TOKENS_LIMIT" else { continue }
            let name = Self.windowName(unit: item.number(for: ["unit"]), number: item.number(for: ["number"]))
            let resetAt = item.number(for: ["nextResetTime"]).map {
                Date(timeIntervalSince1970: $0 > 100_000_000_000 ? $0 / 1000 : $0)
            }
            if let used = item.number(for: ["currentValue"]),
               let limit = item.number(for: ["usage"]), limit > 0 {
                quotas.append(Quota(name: name, used: used, limit: limit, resetAt: resetAt))
            } else if let percentage = item.number(for: ["percentage"]), (0...100).contains(percentage) {
                quotas.append(Quota(name: name, used: percentage, limit: 100, resetAt: resetAt))
            }
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "响应中没有 GLM Coding Plan 订阅额度窗口")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: quotas)
    }

    private static func windowName(unit: Double?, number: Double?) -> String {
        guard let number else { return "限额窗口" }
        let value = Int(number)
        switch unit.map({ Int($0) }) {
        case 3: return "\(value) 小时窗口"
        case 6: return value == 7 ? "每周窗口" : "\(value) 天窗口"
        default: return "限额窗口"
        }
    }
}
