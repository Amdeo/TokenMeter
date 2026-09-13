import AppKit
import WebKit

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
final class EmbeddedWebLoginController: NSObject, NSWindowDelegate {
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

// MARK: - 由配方构造配置

/// 登录窗口配置完全由供应商声明的 `BrowserLoginRecipe` 决定：
/// 共享代码不认识任何供应商，新增站点不需要改这里。
extension EmbeddedWebLoginController.Configuration {
    static func browserLogin(_ recipe: BrowserLoginRecipe) -> Self {
        .init(
            title: recipe.windowTitle,
            sessionDomains: recipe.sessionDomains,
            loginPageURL: recipe.loginPageURL,
            extract: { webView in
                switch recipe.extraction {
                case .localStorageTokens:
                    guard let raw = try? await webView.evaluateJavaScript(
                        recipe.extractionJavaScript
                    ) as? String, !raw.isEmpty else { return nil }
                    return (try? recipe.tokenCredential(from: raw)).map(BrowserLoginResult.token)
                case .sessionCookie(let name, let userIDLocalStorageKey):
                    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    // 共享 Cookie Store 可能含其它站点的同名 cookie，必须按域名过滤。
                    guard let session = cookies.first(where: {
                        $0.name == name
                            && EmbeddedWebLoginController.matches(host: $0.domain, domains: recipe.sessionDomains)
                    }) else { return nil }
                    let userID = await Self.readUserID(from: webView, localStorageKey: userIDLocalStorageKey)
                    return (try? BrowserCookieCredential.credential(
                        cookie: session, name: name, userID: userID, displayName: recipe.displayName
                    )).map(BrowserLoginResult.cookie)
                }
            }
        )
    }

    /// 读取 localStorage 中某个键对应对象的用户 ID。
    @MainActor
    private static func readUserID(from webView: WKWebView, localStorageKey: String) async -> String? {
        guard let raw = try? await webView.evaluateJavaScript(
            BrowserCookieCredential.userIDJavaScript(localStorageKey: localStorageKey)
        ) as? String, !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(UserIDPayload.self, from: Data(raw.utf8)).id
    }

    private struct UserIDPayload: Decodable {
        let id: String
    }
}
