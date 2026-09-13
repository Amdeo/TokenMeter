import Foundation
import WebKit

// MARK: - cookie 型登录态

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
            throw BrowserLoginError.credentialsMissing(provider: displayName)
        }
        let userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userID.isEmpty else {
            throw BrowserLoginError.invalidCredentials(provider: displayName)
        }
        return CookieSessionCredential(
            sessionCookie: "\(cookie.name)=\(cookie.value)",
            userID: userID
        )
    }
}
