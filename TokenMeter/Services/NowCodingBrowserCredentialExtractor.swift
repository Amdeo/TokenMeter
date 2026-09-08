import Foundation
import WebKit

enum NowCodingBrowserCredentialError: LocalizedError, Sendable {
    case credentialsMissing
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "未找到 NowCoding 登录态，请先登录后重试。"
        case .invalidCredentials:
            return "NowCoding 登录态格式无效，请重新登录后重试。"
        }
    }
}

/// NowCoding 网页登录态的提取入口：从 WKWebsiteDataStore 读取 HttpOnly session cookie
/// 并配合 localStorage 中的用户 ID，构造 cookie 型凭证。
/// 内嵌 WKWebView 登录共用同一出口。
enum NowCodingBrowserCredentialExtractor {
    /// 读取 localStorage 中 `user` 对象的用户 ID（数字/字符串统一转字符串），返回 JSON 字符串。
    static let userIDJavaScript =
        #"(() => { const raw = localStorage.getItem("user"); if (!raw) return ""; try { const u = JSON.parse(raw); return JSON.stringify({ id: u.id == null ? "" : String(u.id) }); } catch { return ""; } })()"#

    /// 从 session cookie + 用户 ID 构造凭证。
    static func credential(cookie: HTTPCookie?, userID: String?) throws -> CookieSessionCredential {
        guard let cookie, cookie.name == NowCodingSite.sessionCookieName,
              let sessionValue = cookie.value.data(using: .utf8),
              !sessionValue.isEmpty,
              let cookieValue = String(data: sessionValue, encoding: .utf8), !cookieValue.isEmpty else {
            throw NowCodingBrowserCredentialError.credentialsMissing
        }
        let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userID.isEmpty else {
            throw NowCodingBrowserCredentialError.invalidCredentials
        }
        return CookieSessionCredential(
            sessionCookie: "\(cookie.name)=\(cookieValue)",
            userID: userID
        )
    }
}