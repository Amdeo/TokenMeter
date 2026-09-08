import AppKit
import WebKit

/// 内嵌 WKWebView 的 NowCoding 账号登录窗口：会话由 App 自持，
/// 用户在 NowCoding 官方登录页完成登录后，从 WKWebsiteDataStore 提取
/// HttpOnly session cookie（new-api 新版认证，localStorage 无 token）。
/// 成功返回凭证；用户关窗、超时或任务取消时抛 CancellationError（调用方静默收尾）。
@MainActor
final class EmbeddedNowCodingLoginController: NSObject, NSWindowDelegate, BrowserSessionLogining {
    private static let windowSize = NSSize(width: 920, height: 700)
    private static let pollInterval: Duration = .seconds(1)
    private static let timeout: TimeInterval = 5 * 60

    let sessionDomains = ["nowcoding.ai"]

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var closedByUser = false

    func login() async throws -> BrowserLoginResult {
        showPanel()
        defer { closePanel() }
        let deadline = Date.now.addingTimeInterval(Self.timeout)
        while Date.now < deadline {
            try Task.checkCancellation()
            if closedByUser { throw CancellationError() }
            if let result = await extractIfReady() { return .cookie(result) }
            try await Task.sleep(for: Self.pollInterval)
        }
        throw CancellationError()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        closedByUser = true
    }

    // MARK: - Private

    private func showPanel() {
        let configuration = WKWebViewConfiguration()
        // 持久化站点数据：会话留在 App 内，重登时通常免登录。
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(origin: .zero, size: Self.windowSize), configuration: configuration)
        webView.load(URLRequest(url: NowCodingSite.loginPageURL))
        self.webView = webView

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "登录 NowCoding 账号"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.contentView = webView
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
        webView = nil
    }

    /// 仅在 nowcoding.ai 域内页面尝试提取；未登录（cookie 缺失）时返回 nil 继续等待。
    private func extractIfReady() async -> CookieSessionCredential? {
        guard let webView,
              let host = webView.url?.host?.lowercased(),
              host == "nowcoding.ai" || host.hasSuffix(".nowcoding.ai") else { return nil }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        // 共享 Cookie Store 可能含其它站点的同名 session cookie，必须按域名过滤。
        guard let session = cookies.first(where: {
            $0.name == NowCodingSite.sessionCookieName && Self.isSessionDomain($0.domain)
        }) else { return nil }
        let userID = await readUserID(from: webView)
        return try? NowCodingBrowserCredentialExtractor.credential(cookie: session, userID: userID)
    }

    /// cookie 的 domain 形如 ".nowcoding.ai"（带前导点），匹配主域与子域。
    private static func isSessionDomain(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        return lower == "nowcoding.ai" || lower.hasSuffix(".nowcoding.ai")
    }

    private func readUserID(from webView: WKWebView) async -> String? {
        guard let raw = try? await webView.evaluateJavaScript(NowCodingBrowserCredentialExtractor.userIDJavaScript) as? String,
              !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(UserIDPayload.self, from: Data(raw.utf8)).id
    }

    private struct UserIDPayload: Decodable {
        let id: String
    }
}