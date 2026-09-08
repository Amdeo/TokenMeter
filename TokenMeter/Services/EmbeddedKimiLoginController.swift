import AppKit
import WebKit

/// 内嵌 WKWebView 的浏览器登录窗口协议：返回网页登录态凭证。
/// 各供应商实现自己的登录页加载与 localStorage 提取逻辑。
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

/// 内嵌 WKWebView 的 Kimi 账号登录窗口：会话由 App 自持，
/// 用户在 Kimi 官方登录页完成登录后，自动提取 localStorage 登录态。
/// 成功返回凭证；用户关窗、超时或任务取消时抛 CancellationError（调用方静默收尾）。
@MainActor
final class EmbeddedKimiLoginController: NSObject, NSWindowDelegate, BrowserSessionLogining {
    private static let windowSize = NSSize(width: 920, height: 700)
    private static let pollInterval: Duration = .seconds(1)
    private static let timeout: TimeInterval = 5 * 60

    /// Kimi 登录页在 kimi.com 域内（含 auth/www 等子域）。
    let sessionDomains = ["kimi.com"]

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
            if let credential = await extractIfReady() { return .token(credential) }
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
        webView.load(URLRequest(url: URL(string: ChromeSessionImporter.quotaURL)!))
        self.webView = webView

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "登录 Kimi 账号"
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

    /// 仅在 kimi.com 域内页面尝试提取；未登录（token 缺失/过期）时返回 nil 继续等待。
    private func extractIfReady() async -> KimiBrowserCredential? {
        guard let webView,
              let host = webView.url?.host?.lowercased(),
              host == "kimi.com" || host.hasSuffix(".kimi.com") else { return nil }
        guard let raw = try? await webView.evaluateJavaScript(KimiBrowserCredentialExtractor.extractionJavaScript) as? String,
              !raw.isEmpty else { return nil }
        return try? KimiBrowserCredentialExtractor.credential(from: raw)
    }
}
