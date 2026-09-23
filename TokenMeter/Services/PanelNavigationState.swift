import Foundation
import Observation
import SwiftUI

struct PanelSize: Equatable, Sendable {
    let width: Double
    let height: Double

    static let compact = PanelSize(width: 340, height: 584)
    static let minimumAdaptiveHeight = 320.0
    static let maximumAdaptiveHeight = 900.0
    static let measurementTolerance = 1.0
}

struct PanelHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// 订阅卡片行高度缓存，按稳定的订阅 ID 合并各个 List 行的测量结果。
struct SubscriptionRowHeightsPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 菜单面板的状态：它的尺寸，以及 Debug 的状态预览。
///
/// 它以前还管着面板里的**路由**——设置、添加订阅、编辑订阅、外观、数据迁移都曾是面板里的
/// 二级页。那些现在都在独立设置窗口里，面板只剩概览一页，所以「按路由记住高度」那一整套
/// 也随之消失：高度只剩一个手动值和一个测量值。
///
/// 名字里的 `Navigation` 是历史遗留。`Services/` 不是文件系统同步组，改文件名要同时改
/// `project.pbxproj` 的三处条目，不值得为一个名字付那份代价。
@MainActor
@Observable
final class PanelNavigationState {
    /// Debug 的状态预览（TM-06）由状态栏右键菜单触发，所以状态放在这里而不是视图的
    /// `@State`：菜单是 `MenuBarPanelController` 建的，它够不到视图内部的状态。
    #if DEBUG
    var previewMode: StatusPreviewMode?
    #endif

    private(set) var panelSize = PanelSize.compact
    /// 当前屏幕可视区允许的面板高度上限；由窗口控制器按锚定屏幕设置。
    /// 只是显示上限：既不写回 `panelSize`，也不影响用户保存的手动高度。
    private(set) var maximumVisibleHeight: Double?
    /// 用户拖出来的高度；nil 表示按内容自适应。
    private var manualHeight: Double?
    private let defaults: UserDefaults

    /// 手动高度的存储键。**沿用概览页当年的键**：面板只剩这一页，用户在旧版本里拖出来的
    /// 高度就该继续是这一页的高度，没有理由让他们重拖一次。
    private static let manualHeightKey = "panel.overviewHeight"

    var hasManualHeight: Bool { manualHeight != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let saved = defaults.object(forKey: Self.manualHeightKey) as? Double, saved.isFinite else { return }
        let clamped = Self.clampedHeight(saved)
        manualHeight = clamped
        panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
    }

    func reportMeasuredHeight(_ height: CGFloat) {
        guard height.isFinite else { return }
        let clamped = Self.clampedHeight(Double(height))
        // 被屏幕限高时窗口比期望高度矮，此时量到的高度正好等于窗口高度，说明它是被裁出来的，
        // 不是内容的自适应高度；采纳它会让屏幕恢复后高度回不来。
        guard !isHeightLimitedByScreen
            || abs(clamped - displayedSize.height) >= PanelSize.measurementTolerance else { return }
        guard manualHeight == nil else { return }
        guard abs(clamped - panelSize.height) >= PanelSize.measurementTolerance else { return }
        panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
    }

    /// 面板实际显示的高度：高过屏幕可视区时窗口顶部会跑到屏幕上沿之外
    /// （顶部内容跟着消失），所以窗口与 SwiftUI 根视图都按它收缩。
    var displayedSize: PanelSize {
        guard let maximumVisibleHeight else { return panelSize }
        return PanelSize(width: panelSize.width, height: min(panelSize.height, maximumVisibleHeight))
    }

    /// 屏幕限高是否正在生效：窗口比期望高度矮，内容拿到的高度也被压缩。
    var isHeightLimitedByScreen: Bool {
        guard let maximumVisibleHeight else { return false }
        return maximumVisibleHeight < panelSize.height - PanelSize.measurementTolerance
    }

    func setMaximumVisibleHeight(_ height: Double?) {
        let resolved = height.flatMap { $0.isFinite ? max($0, 0) : nil }
        guard resolved != maximumVisibleHeight else { return }
        maximumVisibleHeight = resolved
    }

    func setUserHeight(_ height: CGFloat, persist: Bool) {
        guard height.isFinite else { return }
        let clamped = Self.clampedHeight(Double(height))
        manualHeight = clamped
        if abs(clamped - panelSize.height) >= PanelSize.measurementTolerance {
            panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
        }
        if persist {
            defaults.set(clamped, forKey: Self.manualHeightKey)
        }
    }

    private static func clampedHeight(_ height: Double) -> Double {
        min(max(height, PanelSize.minimumAdaptiveHeight), PanelSize.maximumAdaptiveHeight)
    }
}


enum OAuthAuthorizationState: Equatable {
    case idle
    case awaitingCallback
    case exchanging
    case completed
}
@MainActor
@Observable
final class SubscriptionEditorDraft {
    let original: Subscription?
    let originalName: String
    let originalAuthMethodID: AuthMethodID
    let initialProviderID: ProviderID
    var providerID: ProviderID
    var authMethodID: AuthMethodID
    var name: String
    /// 按卡片样式隔离的进度条配色；编辑页读写的是 `currentQuotaColors`。
    var quotaColors: SubscriptionQuotaPalette
    var cardStyle: SubscriptionCardStyle
    /// 悬浮条上的呈现配置：是否显示、追踪哪个额度、环的颜色。
    var rail: SubscriptionRailSettings
    var apiKey = ""
    var oauthCredential: OAuthCredential?
    var browserCredential: BrowserTokenCredential?
    var cookieCredential: CookieSessionCredential?
    var oauthDevice: DeviceOAuthAuthorization?
    /// 授权码流程（Claude）：浏览器授权后粘贴回来的授权码或回调地址。
    var oauthCodeInput = ""
    /// 已生成的授权页面地址，供「重新打开」与复制。
    var oauthCodeAuthorizeURL: URL?
    /// 待兑换令牌的 PKCE 参数；离开该认证方式时清空。
    var oauthCodeVerifier: String?
    var oauthCodeState: String?
    var oauthStatus: String?
    var oauthTask: Task<Void, Never>?
    var browserImportTask: Task<Void, Never>?
    var browserImportSessionID = UUID()
    var oauthSessionID = UUID()
    var message: String?

    init(providerID: ProviderID) {
        original = nil
        originalName = ""
        originalAuthMethodID = .apiKey
        initialProviderID = providerID
        self.providerID = providerID
        // 默认认证方式取供应商声明的第一个认证方式；新增供应商无需在此登记。
        authMethodID = ProviderRegistry.defaultAuthMethod(for: providerID) ?? .apiKey
        name = ""
        quotaColors = SubscriptionQuotaPalette()
        cardStyle = .standard
        rail = SubscriptionRailSettings()
    }

    init(subscription: Subscription) {
        original = subscription
        originalName = subscription.name
        originalAuthMethodID = subscription.authMethodID
        initialProviderID = subscription.providerID
        providerID = subscription.providerID
        authMethodID = subscription.authMethodID
        name = subscription.name
        quotaColors = subscription.quotaColors
        cardStyle = subscription.cardStyle
        rail = subscription.rail
    }

    var isEditing: Bool { original != nil }

    /// 当前卡片样式的配色：颜色页与编辑页都读写它，切换样式后各样式配色各自保留。
    var currentQuotaColors: [String: UInt32] {
        get { quotaColors[cardStyle] }
        set { quotaColors[cardStyle] = newValue }
    }
    var isImportingBrowser: Bool { browserImportTask != nil }
    var isAuthenticating: Bool { oauthTask != nil || browserImportTask != nil }

    var oauthCodeAuthorizationState: OAuthAuthorizationState {
        if oauthCredential != nil { return .completed }
        if oauthTask != nil { return .exchanging }
        if oauthCodeAuthorizeURL != nil { return .awaitingCallback }
        return .idle
    }
    var isDirty: Bool {
        if isAuthenticating || oauthCredential != nil || browserCredential != nil || cookieCredential != nil { return true }
        if original == nil {
            return authMethodID != .apiKey
                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || !quotaColors.isEmpty
                || cardStyle != .standard
                || rail != SubscriptionRailSettings()
        }
        return providerID != initialProviderID
            || authMethodID != originalAuthMethodID
            || name != originalName
            || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || quotaColors != original?.quotaColors
            || cardStyle != (original?.cardStyle ?? .standard)
            || rail != (original?.rail ?? SubscriptionRailSettings())
    }

    func cancelTasks() {
        clearOAuthAuthentication()
        leaveBrowserAuthentication()
    }

    /// Cancels and clears all state owned by device and authorization-code OAuth.
    /// Authentication-method changes must not reuse a credential, PKCE verifier,
    /// or presentation text from a different flow.
    func clearOAuthAuthentication() {
        oauthSessionID = UUID()
        oauthTask?.cancel()
        oauthTask = nil
        oauthCredential = nil
        oauthDevice = nil
        oauthStatus = nil
        leaveCodeOAuth()
    }

    /// Clears all transient authentication state before changing methods.
    func clearAuthenticationState() {
        clearOAuthAuthentication()
        leaveBrowserAuthentication()
    }

    /// 清空待兑换的授权码流程参数（切换认证方式或放弃编辑时调用）。
    func leaveCodeOAuth() {
        oauthCodeVerifier = nil
        oauthCodeState = nil
        oauthCodeAuthorizeURL = nil
        oauthCodeInput = ""
    }

    func leaveBrowserAuthentication() {
        browserImportSessionID = UUID()
        browserImportTask?.cancel()
        browserImportTask = nil
        browserCredential = nil
        cookieCredential = nil
    }
}
