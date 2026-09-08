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

/// 订阅卡片行高度之和：每行背景 GeometryReader 上报本行高度，reduce 累加，
/// 驱动列表显式高度，使面板高度仍随内容自适应，超过上限后列表内部滚动。
struct SubscriptionListContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
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
    }

    enum Content {
        case overview
        case settings
        case migration
        case addProvider
        case addConfiguration(SubscriptionEditorDraft)
        case editConfiguration(draft: SubscriptionEditorDraft, subscription: Subscription)
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
        guard measuredRoute != .overview || manualOverviewHeight == nil else { return }
        let clamped = Self.clampedHeight(Double(height))
        guard abs(clamped - panelSize.height) >= PanelSize.measurementTolerance else { return }
        panelSize = PanelSize(width: PanelSize.compact.width, height: clamped)
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
        }
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
    var quotaColors: [String: UInt32]
    var apiKey = ""
    var oauthCredential: OAuthCredential?
    var browserCredential: KimiBrowserCredential?
    var cookieCredential: CookieSessionCredential?
    var oauthDevice: KimiDeviceAuthorization?
    var oauthStatus: String?
    var oauthTask: Task<Void, Never>?
    var browserImportTask: Task<Void, Never>?
    var browserImportSessionID = UUID()
    var oauthSessionID = UUID()
    var message: String?

    init(providerID: ProviderID = .deepSeek) {
        original = nil
        originalName = ""
        originalAuthMethodID = .apiKey
        initialProviderID = providerID
        self.providerID = providerID
        authMethodID = .apiKey
        name = ""
        quotaColors = [:]
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
    }

    var isEditing: Bool { original != nil }
    var isImportingBrowser: Bool { browserImportTask != nil }
    var isAuthenticating: Bool { oauthTask != nil || browserImportTask != nil }
    var isDirty: Bool {
        if isAuthenticating || oauthCredential != nil || browserCredential != nil || cookieCredential != nil { return true }
        if original == nil {
            return authMethodID != .apiKey
                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || !quotaColors.isEmpty
        }
        return providerID != initialProviderID
            || authMethodID != originalAuthMethodID
            || name != originalName
            || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || quotaColors != original?.quotaColors
    }

    func cancelTasks() {
        oauthSessionID = UUID()
        browserImportSessionID = UUID()
        oauthTask?.cancel()
        browserImportTask?.cancel()
        oauthTask = nil
        browserImportTask = nil
    }

    func leaveBrowserAuthentication() {
        browserImportSessionID = UUID()
        browserImportTask?.cancel()
        browserImportTask = nil
        browserCredential = nil
        cookieCredential = nil
    }
}
