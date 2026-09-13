import Foundation

/// 可注入的 HTTP 传输层：生产环境走 `URLSession.shared`，测试可替换为桩，
/// 从而在不发真实请求的前提下覆盖刷新重试、轮询等错误路径。
struct HTTPTransport: Sendable {
    var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.send = send
    }

    static let live = HTTPTransport { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}
