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

struct PanelHeightMeasurement: Equatable {
    let route: PanelNavigationState.Route
    let height: CGFloat
}

struct PanelHeightPreferenceKey: PreferenceKey {
    static let defaultValue: PanelHeightMeasurement? = nil
    static func reduce(value: inout PanelHeightMeasurement?, nextValue: () -> PanelHeightMeasurement?) {
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

@MainActor
@Observable
final class PanelNavigationState {
    enum Route: Equatable, Hashable {
        case overview
        case settings
        case migration
        case addProvider
        case addConfiguration
        case editConfiguration(UUID)
        /// 外观二级页（卡片样式 + 配色 + 预览）；从新建/编辑配置页进入，返回仍在原配置页。
        case appearance
    }

    enum Content {
        case overview
        case settings
        case migration
        case addProvider
        case addConfiguration(SubscriptionEditorDraft)
        case editConfiguration(draft: SubscriptionEditorDraft, subscription: Subscription)
        case appearance(SubscriptionEditorDraft)
        case recovery
    }

    var route: Route = .overview {
        didSet {
            guard route != oldValue else { return }
            if route == .overview, let manualOverviewHeight {
                panelSize = PanelSize(width: PanelSize.compact.width, height: manualOverviewHeight)
            }
        }
    }
    var draft: SubscriptionEditorDraft?
    private(set) var panelSize = PanelSize.compact
    private(set) var manualOverviewHeight: Double?
    /// 每个路由最近一次量到的高度：弹出面板时按当前路由取，不借用其它页面的尺寸
    /// （否则内容比窗口高时 SwiftUI 根视图会被居中，上下两端一起被裁）。
    private var measuredHeights: [Route: Double] = [:]
    private let defaults: UserDefaults

    var hasManualOverviewHeight: Bool { manualOverviewHeight != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let savedHeight = defaults.object(forKey: Self.overviewHeightKey) as? Double,
           savedHeight.isFinite {
            let height = Self.clampedHeight(savedHeight)
            manualOverviewHeight = height
            panelSize = PanelSize(width: PanelSize.compact.width, height: height)
        }
    }

    func reportMeasuredHeight(_ height: CGFloat, for measuredRoute: Route) {
        guard measuredRoute == route, height.isFinite else { return }
        let clamped = Self.clampedHeight(Double(height))
        measuredHeights[measuredRoute] = clamped
        guard measuredRoute != .overview || manualOverviewHeight == nil else { return }
        guard abs(clamped - panelSize.height) >= PanelSize.measurementTolerance else { return }
        panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
    }

    /// 弹出面板时的目标尺寸：取当前路由记住的高度；没有记录时沿用当前尺寸，
    /// 内容随后报出的测量值会把它校准。
    func size(for route: Route) -> PanelSize {
        if route == .overview, let manualOverviewHeight {
            return PanelSize(width: PanelSize.compact.width, height: manualOverviewHeight)
        }
        guard let measured = measuredHeights[route] else { return panelSize }
        return PanelSize(width: PanelSize.compact.width, height: measured)
    }

    func setUserOverviewHeight(_ height: CGFloat, persist: Bool) {
        guard route == .overview, height.isFinite else { return }
        let clamped = Self.clampedHeight(Double(height))
        manualOverviewHeight = clamped
        if abs(clamped - panelSize.height) >= PanelSize.measurementTolerance {
            panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
        }
        if persist {
            defaults.set(clamped, forKey: Self.overviewHeightKey)
        }
    }

    private static let overviewHeightKey = "panel.overviewHeight"

    private static func clampedHeight(_ height: Double) -> Double {
        min(max(height, PanelSize.minimumAdaptiveHeight), PanelSize.maximumAdaptiveHeight)
    }

    func beginAdding() {
        draft = nil
        route = .addProvider
    }

    func selectProvider(_ providerID: ProviderID) {
        draft = SubscriptionEditorDraft(providerID: providerID)
        route = .addConfiguration
    }

    func beginEditingConfiguration(_ subscription: Subscription) {
        draft = SubscriptionEditorDraft(subscription: subscription)
        route = .editConfiguration(subscription.id)
    }

    func content(for subscriptions: [Subscription]) -> Content {
        switch route {
        case .overview: return .overview
        case .settings: return .settings
        case .migration: return .migration
        case .addProvider: return .addProvider
        case .addConfiguration:
            guard let draft, draft.original == nil else { return .recovery }
            return .addConfiguration(draft)
        case .editConfiguration(let id):
            guard let draft, draft.original?.id == id,
                  let subscription = subscriptions.first(where: { $0.id == id })
            else { return .recovery }
            return .editConfiguration(draft: draft, subscription: subscription)
        case .appearance:
            guard let draft else { return .recovery }
            return .appearance(draft)
        }
    }

    /// 进入外观二级页：草稿由配置页延续，样式与颜色改动仍属于同一次编辑。
    func showAppearanceSettings() {
        guard draft != nil else { return }
        route = .appearance
    }

    /// 从外观页返回它来自的配置页（新建或编辑），不丢草稿。
    func returnToEditor() {
        guard let draft else { returnToOverview(); return }
        route = draft.original.map { .editConfiguration($0.id) } ?? .addConfiguration
    }

    func returnToSettings() {
        draft?.cancelTasks()
        draft = nil
        route = .settings
    }

    func returnToOverview() {
        draft?.cancelTasks()
        draft = nil
        route = .overview
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
        }
        return providerID != initialProviderID
            || authMethodID != originalAuthMethodID
            || name != originalName
            || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || quotaColors != original?.quotaColors
            || cardStyle != (original?.cardStyle ?? .standard)
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
