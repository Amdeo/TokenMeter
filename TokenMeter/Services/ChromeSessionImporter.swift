import AppKit
import Foundation

enum ChromeSessionImportError: LocalizedError, Sendable {
    case scriptFailed(String)
    case credentialsMissing
    case invalidCredentials
    case expired

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return "无法从 Chrome 读取 Kimi 登录态：\(message)。请确认 Chrome 已开启“Allow JavaScript from Apple Events”，并允许 TokenMeter 控制 Chrome。"
        case .credentialsMissing:
            return "Chrome 当前 Kimi 页面没有找到登录态，请先登录 Kimi 后重试。"
        case .invalidCredentials:
            return "Chrome 返回的 Kimi 登录态格式无效，请刷新 Kimi 页面后重试。"
        case .expired:
            return "Chrome 中的 Kimi 登录态已过期，请重新登录后重试。"
        }
    }
}

struct ChromeSessionImporter: Sendable {
    static let quotaURL = "https://www.kimi.com/settings/subscription?tab=quota"

    func importCredential() async throws -> KimiBrowserCredential {
        if let credential = try await importViaCDP() {
            return credential
        }
        return try importViaAppleScript()
    }

    static func credential(from rawValue: String) throws -> KimiBrowserCredential {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TokenPayload.self, from: data) else {
            throw ChromeSessionImportError.invalidCredentials
        }
        guard let accessToken = payload.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              let refreshToken = payload.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw ChromeSessionImportError.credentialsMissing
        }
        guard let expiresAt = Self.expiration(of: accessToken) else {
            throw ChromeSessionImportError.invalidCredentials
        }
        guard Self.expiration(of: refreshToken) != nil else {
            throw ChromeSessionImportError.invalidCredentials
        }
        guard expiresAt > .now else {
            throw ChromeSessionImportError.expired
        }
        return KimiBrowserCredential(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, tokenType: "Bearer")
    }

    private func importViaCDP() async throws -> KimiBrowserCredential? {
        guard var pages = try await cdpPages() else { return nil }
        for attempt in 0..<30 {
            if let page = pages.first(where: Self.isKimiPage),
               let webSocketURL = page.webSocketDebuggerURL,
               let rawValue = try? await evaluate(webSocketURL: webSocketURL) {
                return try Self.credential(from: rawValue)
            }
            if attempt == 0 {
                _ = NSWorkspace.shared.open(URL(string: Self.quotaURL)!)
            }
            try await Task.sleep(for: .seconds(1))
            pages = try await cdpPages() ?? pages
        }
        throw ChromeSessionImportError.scriptFailed("未找到可调试的 Kimi Chrome 页面")
    }

    private func cdpPages() async throws -> [CDPPage]? {
        guard let url = URL(string: "http://127.0.0.1:9222/json/list") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else { return nil }
            return try JSONDecoder().decode([CDPPage].self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func evaluate(webSocketURL: String) async throws -> String {
        guard let url = URL(string: webSocketURL) else {
            throw ChromeSessionImportError.scriptFailed("Chrome 调试页面地址无效")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let javascript = #"(() => JSON.stringify({accessToken: localStorage.getItem("access_token"), refreshToken: localStorage.getItem("refresh_token")}))()"#
        let command: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": javascript,
                "returnByValue": true
            ]
        ]
        let commandData = try JSONSerialization.data(withJSONObject: command)
        try await task.send(.string(String(decoding: commandData, as: UTF8.self)))
        while true {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .string(let value): data = Data(value.utf8)
            case .data(let value): data = value
            @unknown default: continue
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int, id == 1 else {
                continue
            }
            if let value = (((object["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String) {
                return value
            }
            throw ChromeSessionImportError.scriptFailed("Chrome 未返回 Kimi 登录态")
        }
    }

    private func importViaAppleScript() throws -> KimiBrowserCredential {
        try Self.credential(from: executeScript())
    }

    private static func isKimiPage(_ page: CDPPage) -> Bool {
        guard let url = page.url else { return false }
        return url.contains("://www.kimi.com") || url.contains("://kimi.com")
    }

    private struct CDPPage: Decodable {
        let url: String?
        let webSocketDebuggerURL: String?

        enum CodingKeys: String, CodingKey {
            case url
            case webSocketDebuggerURL = "webSocketDebuggerUrl"
        }
    }

    private func executeScript() throws -> String {
        let javascript = #"(() => JSON.stringify({accessToken: localStorage.getItem("access_token"), refreshToken: localStorage.getItem("refresh_token")}))()"#
        let escapedJavaScript = javascript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Google Chrome"
            if (count of windows) = 0 then make new window
            set targetTab to missing value
            repeat with browserWindow in windows
                repeat with candidateTab in tabs of browserWindow
                    try
                        set candidateURL to URL of candidateTab
                        if candidateURL contains "://www.kimi.com" or candidateURL contains "://kimi.com" then
                            set targetTab to candidateTab
                            exit repeat
                        end if
                    end try
                end repeat
                if targetTab is not missing value then exit repeat
            end repeat

            if targetTab is missing value then
                set targetTab to make new tab at end of tabs of front window with properties {URL:"\(Self.quotaURL)"}
            end if

            repeat 30 times
                try
                    set tokenJSON to execute targetTab javascript "\(escapedJavaScript)"
                    if tokenJSON is not missing value and tokenJSON is not "" and tokenJSON is not "null" then return tokenJSON
                end try
                delay 1
            end repeat
            error "Kimi 页面未返回登录态"
        end tell
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw ChromeSessionImportError.scriptFailed("无法创建 Chrome 自动化脚本")
        }
        let result = script.executeAndReturnError(&error)
        guard let value = result.stringValue,
              !value.isEmpty else {
            let message = (error?[NSAppleScript.errorMessage] as? String) ?? "Chrome 自动化不可用"
            throw ChromeSessionImportError.scriptFailed(message)
        }
        return value
    }

    private static func expiration(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["exp"] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: value.doubleValue)
    }

    private struct TokenPayload: Decodable {
        let accessToken: String?
        let refreshToken: String?
    }
}
