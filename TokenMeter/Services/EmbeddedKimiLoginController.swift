import AppKit
import WebKit

/// 内嵌 WKWebView 的 Kimi 账号登录窗口：会话由 App 自持，
/// 用户在 Kimi 官方登录页完成登录后，自动提取 localStorage 登录态。
/// 成功返回凭证；用户关窗、超时或任务取消时抛 CancellationError（调用方静默收尾）。
@MainActor
final class EmbeddedKimiLoginController: NSObject, NSWindowDelegate {
    private static let windowSize = NSSize(width: 920, height: 700)
    private static let pollInterval: Duration = .seconds(1)
    private static let timeout: TimeInterval = 5 * 60

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var closedByUser = false

    func login() async throws -> KimiBrowserCredential {
        showPanel()
        defer { closePanel() }
        let deadline = Date.now.addingTimeInterval(Self.timeout)
        while Date.now < deadline {
            try Task.checkCancellation()
            if closedByUser { throw CancellationError() }
            if let credential = await extractIfReady() { return credential }
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
