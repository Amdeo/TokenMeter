import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let miniMax = ProviderID(rawValue: "minimax")
}

// MARK: - 定义

struct MiniMaxProviderDefinition: ProviderDefinition {
    let id = ProviderID.miniMax

    /// 旧 `Platform` 枚举里的名字。
    var legacyPlatformNames: [String] { ["MiniMax"] }

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "MiniMax",
            iconResourceName: "icon-minimax",
            fallbackSystemImage: "cube.fill",
            tintRGB: 0xFF9F0A,
            capabilityDescription: "支持 MiniMax Coding Plan 套餐额度。",
            authPageURL: URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key"),
            homepageURL: URL(string: "https://platform.minimaxi.com"),
            authenticationSummary: "API Key · 支持 MiniMax Coding Plan 套餐额度"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台")]
    }

    @MainActor var cardRenderer: any ProviderCardRenderer { QuotaListCardRenderer() }

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        MiniMaxUsageProvider(subscription: subscription)
    }

}

// MARK: - 用量提供者

struct MiniMaxUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let response: MiniMaxRemainsResponse = try await APIClient.get(
            URL(string: "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains")!,
            providerID: subscription.providerID,
            authorization: "Bearer \(key)"
        )
        guard response.baseResp.statusCode == 0 else {
            throw UsageProviderError.invalidResponse(subscription.providerID, response.baseResp.statusMsg ?? "接口返回错误")
        }
        let quotas = response.modelRemains.compactMap { model -> Quota? in
            guard let total = model.currentIntervalTotalCount?.value,
                  let remaining = model.currentIntervalUsageCount?.value,
                  total > 0 else { return nil }
            let resetAt = model.endTime?.value.map { Date(timeIntervalSince1970: $0 / 1000) }
            return Quota(name: model.modelName ?? "Coding Plan 额度", used: max(0, total - remaining), limit: total, resetAt: resetAt)
        }
        guard !quotas.isEmpty else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "MiniMax Coding Plan 返回中没有套餐额度")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: quotas)
    }
}

// MARK: - 响应类型

private struct MiniMaxRemainsResponse: Decodable {
    struct ModelRemain: Decodable {
        let modelName: String?
        let endTime: FlexibleNumber?
        let currentIntervalTotalCount: FlexibleNumber?
        let currentIntervalUsageCount: FlexibleNumber?

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case endTime = "end_time"
            case currentIntervalTotalCount = "current_interval_total_count"
            case currentIntervalUsageCount = "current_interval_usage_count"
        }
    }

    struct BaseResp: Decodable {
        let statusCode: Int
        let statusMsg: String?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMsg = "status_msg"
        }
    }

    let modelRemains: [ModelRemain]
    let baseResp: BaseResp

    enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }
}
