import Foundation

protocol UsageProvider: Sendable {
    var subscription: Subscription { get }
    func fetchUsage() async throws -> UsageSnapshot
}

enum UsageProviderError: LocalizedError {
    case notConfigured(Platform)
    case unsupported(Platform)
    case authenticationRequired(Platform, String)
    case requestFailed(Platform, String)
    case httpStatus(Int)
    case invalidResponse(Platform, String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .notConfigured(let platform): "未配置 \(platform.rawValue) 凭证"
        case .unsupported(let platform): "\(platform.rawValue) 暂无确认稳定的公开额度接口"
        case .authenticationRequired(let platform, let message): "\(platform.rawValue) 认证失败：\(message)"
        case .requestFailed(let platform, let message): "\(platform.rawValue) 请求失败：\(message)"
        case .httpStatus(let status): "接口返回错误（HTTP \(status)）"
        case .invalidResponse(let platform, let message): "\(platform.rawValue) 返回数据无法解析：\(message)"
        case .invalidJSON: "接口返回了无效 JSON"
        }
    }
}
