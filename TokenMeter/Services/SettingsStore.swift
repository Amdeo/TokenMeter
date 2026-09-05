import Foundation
import ServiceManagement
import UserNotifications
import Observation
import AppKit

enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound

    var isEnabled: Bool { self == .enabled }
    var label: String {
        switch self {
        case .enabled: "已启用"
        case .requiresApproval: "需要系统批准"
        case .notRegistered: "未启用"
        case .notFound: "系统未找到登录项"
        }
    }
}

protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@available(macOS 13.0, *)
struct SystemLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notRegistered
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

protocol NotificationAuthorizationManaging {
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void)
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void)
}

struct SystemNotificationAuthorizationManager: NotificationAuthorizationManaging {
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in completion(granted) }
    }
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in completion(settings.authorizationStatus) }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private let loginItemManager: LoginItemManaging
    private let notificationManager: NotificationAuthorizationManaging
    private(set) var loginItemError: String?
    private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    private(set) var launchAtLogin: Bool
    var refreshOnOpen: Bool { didSet { defaults.set(refreshOnOpen, forKey: Keys.refreshOnOpen) } }
    var autoRefreshEnabled: Bool { didSet { defaults.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) } }
    var lowBalanceAlerts: Bool {
        didSet {
            defaults.set(lowBalanceAlerts, forKey: Keys.lowBalanceAlerts)
            if lowBalanceAlerts && !oldValue { requestNotificationsIfNeeded() }
        }
    }
    var authenticationAlerts: Bool {
        didSet {
            defaults.set(authenticationAlerts, forKey: Keys.authenticationAlerts)
            if authenticationAlerts && !oldValue { requestNotificationsIfNeeded() }
        }
    }
    var serviceErrorAlerts: Bool {
        didSet {
            defaults.set(serviceErrorAlerts, forKey: Keys.serviceErrorAlerts)
            if serviceErrorAlerts && !oldValue { requestNotificationsIfNeeded() }
        }
    }
    var cnyBalanceThreshold: Double {
        didSet {
            if cnyBalanceThreshold < 0 { cnyBalanceThreshold = 0 }
            defaults.set(cnyBalanceThreshold, forKey: Keys.cnyThreshold)
        }
    }
    var usdBalanceThreshold: Double {
        didSet {
            if usdBalanceThreshold < 0 { usdBalanceThreshold = 0 }
            defaults.set(usdBalanceThreshold, forKey: Keys.usdThreshold)
        }
    }

    var notificationStatusLabel: String {
        switch notificationStatus {
        case .authorized: "通知已授权"
        case .provisional: "通知为临时授权"
        case .ephemeral: "通知为临时会话授权"
        case .denied: "通知未授权"
        case .notDetermined: "通知权限未决定"
        @unknown default: "通知状态未知"
        }
    }

    init(
        defaults: UserDefaults = .standard,
        loginItemManager: LoginItemManaging? = nil,
        notificationManager: NotificationAuthorizationManaging? = nil
    ) {
        self.defaults = defaults
        self.loginItemManager = loginItemManager ?? SystemLoginItemManager()
        self.notificationManager = notificationManager ?? SystemNotificationAuthorizationManager()
        launchAtLogin = false
        refreshOnOpen = defaults.object(forKey: Keys.refreshOnOpen) as? Bool ?? true
        autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? true
        lowBalanceAlerts = defaults.object(forKey: Keys.lowBalanceAlerts) as? Bool ?? true
        authenticationAlerts = defaults.object(forKey: Keys.authenticationAlerts) as? Bool ?? true
        serviceErrorAlerts = defaults.object(forKey: Keys.serviceErrorAlerts) as? Bool ?? false
        cnyBalanceThreshold = max(0, defaults.object(forKey: Keys.cnyThreshold) as? Double ?? 5)
        usdBalanceThreshold = max(0, defaults.object(forKey: Keys.usdThreshold) as? Double ?? 1)
        refreshLoginItemStatus()
        updateNotificationStatus()
    }

    func refreshLoginItemStatus() {
        applyLoginItemStatus(loginItemManager.status)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLogin || loginItemStatus != (enabled ? .enabled : .notRegistered) else { return }
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try loginItemManager.register()
            } else {
                try loginItemManager.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }
    func requestNotificationsIfNeeded() {
        notificationManager.requestAuthorization { [weak self] _ in
            Task { @MainActor in self?.updateNotificationStatus() }
        }
    }

    func updateNotificationStatus() {
        notificationManager.getStatus { [weak self] status in
            Task { @MainActor in self?.notificationStatus = status }
        }
    }

    func openNotificationSettings() {
        guard let settingsURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else { return }
        NSWorkspace.shared.openApplication(at: settingsURL, configuration: NSWorkspace.OpenConfiguration())
    }

    private func applyLoginItemStatus(_ status: LoginItemStatus) {
        loginItemStatus = status
        launchAtLogin = status.isEnabled
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
    }

    private enum Keys {
        static let launchAtLogin = "settings.launchAtLogin"
        static let refreshOnOpen = "settings.refreshOnOpen"
        static let autoRefreshEnabled = "settings.autoRefreshEnabled"
        static let lowBalanceAlerts = "settings.lowBalanceAlerts"
        static let authenticationAlerts = "settings.authenticationAlerts"
        static let serviceErrorAlerts = "settings.serviceErrorAlerts"
        static let cnyThreshold = "settings.cnyBalanceThreshold"
        static let usdThreshold = "settings.usdBalanceThreshold"
    }
}
