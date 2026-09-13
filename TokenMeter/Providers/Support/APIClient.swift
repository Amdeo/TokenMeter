import Foundation
import os

/// 用量请求日志器（subsystem: com.tokenmeter.app）。
enum UsageLogger {
    static let logger = Logger(subsystem: "com.tokenmeter.app", category: "usage")
}

/// 数字/字符串二义字段的宽松解析（供应商接口常把数字序列化成字符串）。
struct FlexibleNumber: Decodable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
    }
}

/// 非 2xx 响应的错误映射策略。
///
/// 供应商在自己文件里声明用哪一种：API Key 型希望 401/403 直接呈现为「凭证失效」，
/// 而浏览器会话型与 OAuth 型必须先拿到原始 `httpStatus`，才能触发
/// `BrowserSessionFlow` 的「刷新一次再重试」。共享层因此不含任何供应商名字。
struct HTTPStatusPolicy: Sendable {
    enum UnauthorizedHandling: Sendable {
        /// 转成 `authenticationRequired`：凭证直接判为失效。
        case authenticationRequired
        /// 原样抛出 `httpStatus`，由调用方决定是否刷新重试。
        case raw
    }

    var unauthorized: UnauthorizedHandling = .authenticationRequired
    /// 401/403 的专用文案；缺省使用通用文案。
    var unauthorizedMessage: String?
    /// 其它状态码的专用文案，例如余额不足（402）与限流（429）。
    var messages: [Int: String] = [:]

    /// API Key 型供应商的默认行为：401/403 视为凭证失效。
    static let invalidCredential = HTTPStatusPolicy()

    /// 浏览器会话型 / OAuth 型：401/403 交给各自的刷新流程处理。
    static let raw = HTTPStatusPolicy(unauthorized: .raw)
}

/// 共享 HTTP 客户端：GET/POST JSON，统一的日志、状态码错误分类。
enum APIClient {
    static func get<Response: Decodable>(
        _ url: URL,
        providerID: ProviderID,
        authorization: String,
        headers: [String: String] = [:],
        statusPolicy: HTTPStatusPolicy = .invalidCredential,
        transport: HTTPTransport = .live
    ) async throws -> Response {
        UsageLogger.logger.debug("request started provider=\(providerID.rawValue, privacy: .public) type=\(String(describing: Response.self), privacy: .public)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, httpResponse) = try await transport.send(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            UsageLogger.logger.error("""
                response rejected \
                provider=\(providerID.rawValue, privacy: .public) \
                status=\(httpResponse.statusCode, privacy: .public) \
                byteCount=\(data.count, privacy: .public) \
                type=\(String(describing: Response.self), privacy: .public) \
                errorClass=httpStatus
                """)
            throw statusError(providerID: providerID, status: httpResponse.statusCode, policy: statusPolicy)
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            UsageLogger.logger.info("""
                response decoded \
                provider=\(providerID.rawValue, privacy: .public) \
                status=\(httpResponse.statusCode, privacy: .public) \
                byteCount=\(data.count, privacy: .public) \
                type=\(String(describing: Response.self), privacy: .public)
                """)
            return decoded
        } catch {
            UsageLogger.logger.error("""
                response decode failed \
                provider=\(providerID.rawValue, privacy: .public) \
                status=\(httpResponse.statusCode, privacy: .public) \
                byteCount=\(data.count, privacy: .public) \
                type=\(String(describing: Response.self), privacy: .public) \
                errorClass=invalidJSON
                """)
            throw UsageProviderError.invalidJSON
        }
    }

    static func post<Response: Decodable>(
        _ url: URL,
        providerID: ProviderID,
        authorization: String,
        headers: [String: String] = [:],
        body: Data = Data("{}".utf8),
        statusPolicy: HTTPStatusPolicy = .invalidCredential,
        transport: HTTPTransport = .live
    ) async throws -> Response {
        UsageLogger.logger.debug("request started provider=\(providerID.rawValue, privacy: .public) type=\(String(describing: Response.self), privacy: .public)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        let (data, httpResponse) = try await transport.send(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw statusError(providerID: providerID, status: httpResponse.statusCode, policy: statusPolicy)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageProviderError.invalidJSON
        }
    }

    /// 状态码 → 错误分类。语义完全由调用方声明的 `HTTPStatusPolicy` 决定，
    /// 这里不认识任何供应商。
    private static func statusError(
        providerID: ProviderID,
        status: Int,
        policy: HTTPStatusPolicy
    ) -> UsageProviderError {
        if let message = policy.messages[status] {
            return .requestFailed(providerID, message)
        }
        switch status {
        case 401, 403:
            switch policy.unauthorized {
            case .authenticationRequired:
                return .authenticationRequired(providerID, policy.unauthorizedMessage ?? "凭证无效或无权访问接口")
            case .raw:
                return .httpStatus(status)
            }
        default:
            return .httpStatus(status)
        }
    }
}
