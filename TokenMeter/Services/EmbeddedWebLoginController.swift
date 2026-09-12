import AppKit
import WebKit

/// 内嵌 WKWebView 的浏览器登录窗口协议：返回网页登录态凭证。
/// 各供应商的登录页加载与 localStorage 提取逻辑由 `EmbeddedWebLoginController.Configuration` 提供。
@MainActor
protocol BrowserSessionLogining {
    /// 内置浏览器会话覆盖的目标域（含子域），切换账号时用于清除站点数据。
    var sessionDomains: [String] { get }
    func login() async throws -> BrowserLoginResult
}

/// 内置浏览器会话的站点数据：按域清除 WKWebView 持久化数据，使登录页回到未登录态。
/// 只影响内嵌登录窗口的免登录会话，不影响已保存到凭证文件的网页登录态凭证。
enum BrowserSessionSiteData {
    /// WKWebsiteDataRecord.displayName 是否属于目标域（含子域；忽略大小写与前导点）。
    static func matches(domain: String, recordDisplayName: String) -> Bool {
        var host = recordDisplayName.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        let domain = domain.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    /// 清除默认数据存储中属于目标域的全部站点数据；无匹配记录时不做任何事。
    @MainActor
    static func clear(domains: [String]) async {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        let targets = records.filter { record in
            domains.contains { matches(domain: $0, recordDisplayName: record.displayName) }
        }
        guard !targets.isEmpty else { return }
        await dataStore.removeData(ofTypes: types, for: targets)
    }
}

/// 内嵌 WKWebView 的浏览器登录窗口：会话由 App 自持，用户在供应商官方登录页
/// 完成登录后自动提取登录态。成功返回凭证；用户关窗、超时或任务取消时抛
/// CancellationError（调用方静默收尾）。
///
/// 原先 Kimi / CCBus / APIKEY.FUN / NowCoding 各自维护了一份逐行相同的控制器，
/// 差异只有标题、域名、登录页地址与提取方式；现在这些差异收敛为 `Configuration`。
@MainActor
final class EmbeddedWebLoginController: NSObject, NSWindowDelegate, BrowserSessionLogining {
    /// 单个供应商的登录窗口配置。窗口尺寸、轮询间隔与超时对所有供应商一致。
    struct Configuration {
        /// 窗口标题，例如「登录 Kimi 账号」。
        let title: String
        /// 登录页所在域（含子域），用于判定何时可以尝试提取，也用于切换账号时清站点数据。
        let sessionDomains: [String]
        /// 打开窗口时加载的页面地址。
        let loginPageURL: URL
        /// 页面位于目标域时提取登录态；未登录返回 nil 以继续轮询。
        let extract: @MainActor (WKWebView) async -> BrowserLoginResult?
    }

    private static let windowSize = NSSize(width: 920, height: 700)
    private static let pollInterval: Duration = .seconds(1)
    private static let timeout: TimeInterval = 5 * 60

    let sessionDomains: [String]
    private let configuration: Configuration

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var closedByUser = false

    init(configuration: Configuration) {
        self.configuration = configuration
        self.sessionDomains = configuration.sessionDomains
        super.init()
    }

    func login() async throws -> BrowserLoginResult {
        showPanel()
        defer { closePanel() }
        let deadline = Date.now.addingTimeInterval(Self.timeout)
        while Date.now < deadline {
            try Task.checkCancellation()
            if closedByUser { throw CancellationError() }
            if let result = await extractIfReady() { return result }
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
        let webViewConfiguration = WKWebViewConfiguration()
        // 持久化站点数据：会话留在 App 内，重登时通常免登录。
        webViewConfiguration.websiteDataStore = .default()
        let webView = WKWebView(
            frame: NSRect(origin: .zero, size: Self.windowSize),
            configuration: webViewConfiguration
        )
        webView.load(URLRequest(url: configuration.loginPageURL))
        self.webView = webView

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = configuration.title
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

    /// 仅在目标域内页面尝试提取；未登录时返回 nil 继续等待。
    private func extractIfReady() async -> BrowserLoginResult? {
        guard let webView,
              let host = webView.url?.host?.lowercased(),
              Self.matches(host: host, domains: sessionDomains) else { return nil }
        return await configuration.extract(webView)
    }

    /// 页面 host 是否属于目标域（含子域）。纯字符串判定，与窗口状态无关。
    nonisolated static func matches(host: String, domains: [String]) -> Bool {
        domains.contains { BrowserSessionSiteData.matches(domain: $0, recordDisplayName: host) }
    }
}

// MARK: - 各供应商配置

/// 各供应商的登录窗口配置。差异只在标题、域名、登录页地址与提取方式；
/// 窗口行为由 `EmbeddedWebLoginController` 统一承担。
extension EmbeddedWebLoginController.Configuration {
    /// token 型供应商（Kimi / CCBus / APIKEY.FUN / Siyu）：差异全在 `BrowserTokenSite`。
    static func tokenLogin(_ site: BrowserTokenSite) -> Self {
        .init(
            title: site.loginWindowTitle,
            sessionDomains: site.sessionDomains,
            loginPageURL: site.loginPageURL,
            extract: { webView in
                guard let raw = try? await webView.evaluateJavaScript(
                    site.extractionJavaScript
                ) as? String, !raw.isEmpty else { return nil }
                return (try? site.credential(from: raw)).map(BrowserLoginResult.token)
            }
        )
    }

    /// Kimi：登录页即用量页。
    static var kimi: Self { tokenLogin(.kimi) }

    /// CCBus（AI 巴士）。
    static var ccbus: Self { tokenLogin(.ccbus) }

    /// Siyu API。
    static var siyu: Self { tokenLogin(.siyu) }

    /// APIKEY.FUN。
    static var apiKeyFun: Self { tokenLogin(.apiKeyFun) }

    /// NowCoding：new-api 新版认证，localStorage 无 token，
    /// 登录态是 WKWebsiteDataStore 里的 HttpOnly session cookie + localStorage 用户 ID。
    static var nowCoding: Self {
        .init(
            title: "登录 NowCoding 账号",
            sessionDomains: ["nowcoding.ai"],
            loginPageURL: NowCodingSite.loginPageURL,
            extract: { webView in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                // 共享 Cookie Store 可能含其它站点的同名 session cookie，必须按域名过滤。
                guard let session = cookies.first(where: {
                    $0.name == NowCodingSite.sessionCookieName
                        && EmbeddedWebLoginController.matches(host: $0.domain, domains: ["nowcoding.ai"])
                }) else { return nil }
                let userID = await Self.readUserID(from: webView)
                return (try? NowCodingBrowserCredentialExtractor.credential(cookie: session, userID: userID))
                    .map(BrowserLoginResult.cookie)
            }
        )
    }

    /// 读取 localStorage 中 `user` 对象的用户 ID。
    @MainActor
    private static func readUserID(from webView: WKWebView) async -> String? {
        guard let raw = try? await webView.evaluateJavaScript(
            NowCodingBrowserCredentialExtractor.userIDJavaScript
        ) as? String, !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(UserIDPayload.self, from: Data(raw.utf8)).id
    }

    private struct UserIDPayload: Decodable {
        let id: String
    }
}
