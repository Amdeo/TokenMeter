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
        case migration
        case addProvider
        case addConfiguration
        case editConfiguration(UUID)
        /// 外观二级页（卡片样式 + 配色 + 预览）；从新建/编辑配置页进入，返回仍在原配置页。
        case appearance
    }

    enum Content {
        case overview
        case migration
        case addProvider
        case addConfiguration(SubscriptionEditorDraft)
        case editConfiguration(draft: SubscriptionEditorDraft, subscription: Subscription)
        case appearance(SubscriptionEditorDraft)
        case recovery
    }

    /// Debug 的状态预览（TM-06）由状态栏右键菜单触发，所以状态放在这里而不是视图的
    /// `@State`：菜单是 `MenuBarPanelController` 建的，它够不到视图内部的状态。
    #if DEBUG
    var previewMode: StatusPreviewMode?
    #endif

    var route: Route = .overview {
        didSet {
            guard route != oldValue else { return }
            // 切页立刻用上目标页记住的高度（手动高度优先，其次它上次的测量值）。
            // 如果等新页面报出测量值再改，两次更新之间原生窗口与 SwiftUI 根视图会不同高，
            // 内容被居中裁掉首尾，顶部的返回按钮既看不到也点不到。
            let adopted = size(for: route)
            guard adopted != panelSize else { return }
            panelSize = adopted
        }
    }
    var draft: SubscriptionEditorDraft?
    private(set) var panelSize = PanelSize.compact
    /// 当前屏幕可视区允许的面板高度上限；由窗口控制器按锚定屏幕设置。
    /// 只是显示上限：既不写回 `panelSize`，也不影响用户保存的手动高度。
    private(set) var maximumVisibleHeight: Double?
    private var manualHeights: [HeightRoute: Double] = [:]
    /// 每个路由最后量到的高度：切页与弹出面板都按当前路由取，不借用其它页面的尺寸
    /// （否则内容比窗口高时 SwiftUI 根视图会被居中，上下两端一起被裁）。
    private var measuredHeights: [Route: Double] = [:]
    private let defaults: UserDefaults

    var hasManualHeight: Bool { manualHeight(for: route) != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for heightRoute in HeightRoute.allCases {
            guard let savedHeight = defaults.object(forKey: heightRoute.defaultsKey) as? Double,
                  savedHeight.isFinite else { continue }
            manualHeights[heightRoute] = Self.clampedHeight(savedHeight)
        }
        if let manualHeight = manualHeight(for: route) {
            panelSize = PanelSize(width: PanelSize.compact.width, height: manualHeight)
        }
    }

    func reportMeasuredHeight(_ height: CGFloat, for measuredRoute: Route) {
        guard measuredRoute == route, height.isFinite else { return }
        let clamped = Self.clampedHeight(Double(height))
        // 被屏幕限高时窗口比期望高度矮，此时量到的高度正好等于窗口高度，说明它是被裁出来的，
        // 不是内容的自适应高度；采纳它会让屏幕恢复后高度回不来。
        guard !isHeightLimitedByScreen
            || abs(clamped - displayedSize.height) >= PanelSize.measurementTolerance else { return }
        measuredHeights[measuredRoute] = clamped
        guard manualHeight(for: measuredRoute) == nil else { return }
        guard abs(clamped - panelSize.height) >= PanelSize.measurementTolerance else { return }
        panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
    }

    /// 面板实际显示的高度：高过屏幕可视区时窗口顶部会跑到屏幕上沿之外
    /// （返回按钮跟着消失），所以窗口与 SwiftUI 根视图都按它收缩。
    var displayedSize: PanelSize {
        guard let maximumVisibleHeight else { return panelSize }
        return PanelSize(width: panelSize.width, height: min(panelSize.height, maximumVisibleHeight))
    }

    /// 屏幕限高是否正在生效：窗口比期望高度矮，页面拿到的高度也被压缩。
    var isHeightLimitedByScreen: Bool {
        guard let maximumVisibleHeight else { return false }
        return maximumVisibleHeight < panelSize.height - PanelSize.measurementTolerance
    }

    func setMaximumVisibleHeight(_ height: Double?) {
        let resolved = height.flatMap { $0.isFinite ? max($0, 0) : nil }
        guard resolved != maximumVisibleHeight else { return }
        maximumVisibleHeight = resolved
    }

    /// 某个路由的目标尺寸：手动高度优先，其次它上次的测量值；都没有就沿用当前尺寸，
    /// 内容随后报出的测量值会把它校准。切页与弹出面板都走它。
    func size(for route: Route) -> PanelSize {
        if let manualHeight = manualHeight(for: route) {
            return PanelSize(width: PanelSize.compact.width, height: manualHeight)
        }
        guard let measured = measuredHeights[route] else { return panelSize }
        return PanelSize(width: PanelSize.compact.width, height: measured)
    }

    func setUserHeight(_ height: CGFloat, persist: Bool) {
        guard height.isFinite else { return }
        let clamped = Self.clampedHeight(Double(height))
        let heightRoute = HeightRoute(route)
        manualHeights[heightRoute] = clamped
        if abs(clamped - panelSize.height) >= PanelSize.measurementTolerance {
            panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
        }
        if persist {
            defaults.set(clamped, forKey: heightRoute.defaultsKey)
        }
    }

    private func manualHeight(for route: Route) -> Double? {
        manualHeights[HeightRoute(route)]
    }

    private enum HeightRoute: String, CaseIterable {
        case overview
        case migration
        case addProvider
        case addConfiguration
        case editConfiguration
        case appearance

        init(_ route: Route) {
            self = switch route {
            case .overview: .overview
            case .migration: .migration
            case .addProvider: .addProvider
            case .addConfiguration: .addConfiguration
            case .editConfiguration: .editConfiguration
            case .appearance: .appearance
            }
        }

        var defaultsKey: String {
            self == .overview ? "panel.overviewHeight" : "panel.\(rawValue)Height"
        }
    }

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
