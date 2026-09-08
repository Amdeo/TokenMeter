import Foundation

protocol UsageProvider: Sendable {
    var subscription: Subscription { get }
    func fetchUsage() async throws -> UsageSnapshot
}

enum UsageProviderError: LocalizedError {
    case notConfigured(ProviderID)
    case unsupported(ProviderID)
    case authenticationRequired(ProviderID, String)
    case requestFailed(ProviderID, String)
    case httpStatus(Int)
    case invalidResponse(ProviderID, String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .notConfigured(let providerID): "未配置 \(providerID.rawValue) 凭证"
        case .unsupported(let providerID): "\(providerID.rawValue) 暂无确认稳定的公开额度接口"
        case .authenticationRequired(let providerID, let message): "\(providerID.rawValue) 认证失败：\(message)"
        case .requestFailed(let providerID, let message): "\(providerID.rawValue) 请求失败：\(message)"
        case .httpStatus(let status): "接口返回错误（HTTP \(status)）"
        case .invalidResponse(let providerID, let message): "\(providerID.rawValue) 返回数据无法解析：\(message)"
        case .invalidJSON: "接口返回了无效 JSON"
        }
    }
}
