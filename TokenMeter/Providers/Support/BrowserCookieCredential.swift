import Foundation
import WebKit

// MARK: - cookie 型登录态

/// cookie 型网页登录态的统一错误，文案里的供应商名由调用方提供。
enum BrowserCookieCredentialError: LocalizedError, Sendable, Equatable {
    case credentialsMissing(provider: String)
    case invalidCredentials(provider: String)

    var errorDescription: String? {
        switch self {
        case .credentialsMissing(let provider):
            "未找到 \(provider) 登录态，请先登录后重试。"
        case .invalidCredentials(let provider):
            "\(provider) 登录态格式无效，请重新登录后重试。"
        }
    }
}

/// 从 HttpOnly session cookie + localStorage 用户 ID 构造 cookie 型凭证。
/// new-api 系站点共用这一份提取逻辑，差异只有 cookie 名与 localStorage 键名。
enum BrowserCookieCredential {
    /// 读取 localStorage 中某个键对应对象的 `id` 字段，返回 JSON 字符串。
    /// 数字与字符串统一转成字符串；缺键、非 JSON、无 id 都返回空串。
    static func userIDJavaScript(localStorageKey: String) -> String {
        #"(() => { const raw = localStorage.getItem("\#(localStorageKey)"); if (!raw) return ""; try { const u = JSON.parse(raw); return JSON.stringify({ id: u.id == null ? "" : String(u.id) }); } catch { return ""; } })()"#
    }

    /// 从 session cookie + 用户 ID 构造凭证；缺 cookie 与缺用户 ID 分别报错。
    static func credential(
        cookie: HTTPCookie?,
        name: String,
        userID: String?,
        displayName: String
    ) throws -> CookieSessionCredential {
        guard let cookie, cookie.name == name,
              !cookie.value.isEmpty else {
            throw BrowserCookieCredentialError.credentialsMissing(provider: displayName)
        }
        let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userID.isEmpty else {
            throw BrowserCookieCredentialError.invalidCredentials(provider: displayName)
        }
        return CookieSessionCredential(
            sessionCookie: "\(cookie.name)=\(cookie.value)",
            userID: userID
        )
    }
}
