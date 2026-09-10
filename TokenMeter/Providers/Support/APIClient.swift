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

/// 共享 HTTP 客户端：GET/POST JSON，统一的日志、状态码错误分类。
enum APIClient {
    static func get<Response: Decodable>(_ url: URL, providerID: ProviderID, authorization: String, headers: [String: String] = [:], transport: HTTPTransport = .live) async throws -> Response {
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
            switch (providerID, httpResponse.statusCode) {
            case (.deepSeek, 401), (.deepSeek, 403):
                throw UsageProviderError.authenticationRequired(providerID, "API Key 无效或无权访问余额接口")
            case (.deepSeek, 402):
                throw UsageProviderError.requestFailed(providerID, "账户余额不足")
            case (.deepSeek, 429):
                throw UsageProviderError.requestFailed(providerID, "请求过于频繁，请稍后重试")
            default:
                throw statusError(providerID: providerID, status: httpResponse.statusCode)
            }
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
            throw statusError(providerID: providerID, status: httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageProviderError.invalidJSON
        }
    }

    /// 状态码 → 错误分类。401/403 对多数供应商是凭证无效（进入认证失效状态）；
    /// 但回退余额（Kimi）与续期重试（CCBus/APIKEY.FUN/NowCoding/Codex/Claude）的 Provider 层
    /// 自己处理 401/403 语义，这里保持 `httpStatus` 原样抛出。
    private static func statusError(providerID: ProviderID, status: Int) -> UsageProviderError {
        switch status {
        case 401, 403:
            if providerID == .kimi || providerID == .ccbus || providerID == .apikeyFun || providerID == .nowCoding || providerID == .codex || providerID == .claude {
                return .httpStatus(status)
            }
            return .authenticationRequired(providerID, "凭证无效或无权访问接口")
        default:
            return .httpStatus(status)
        }
    }
}
