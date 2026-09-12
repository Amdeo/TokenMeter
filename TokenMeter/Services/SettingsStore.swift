import Foundation
import ServiceManagement
import UserNotifications
import Observation
import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

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
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void)
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void)
}

struct SystemNotificationAuthorizationManager: NotificationAuthorizationManaging {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(granted))
            }
        }
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
    /// 最近一次通知授权请求的失败原因；nil 表示没有已知失败。
    /// 系统拒绝注册（未签名构建）时状态会一直停留在 `.notDetermined`，
    /// 必须把原因显式暴露出来，否则界面表现为「点按钮没有任何反应」。
    private(set) var notificationRequestError: String?

    private(set) var launchAtLogin: Bool
    var appearanceMode: AppearanceMode { didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) } }
    /// 浅色外观下是否使用磨砂玻璃背景；关闭时面板显示纯白背景。深色外观始终用深色渐变。
    var glassEffectEnabled: Bool { didSet { defaults.set(glassEffectEnabled, forKey: Keys.glassEffectEnabled) } }
    var refreshOnOpen: Bool { didSet { defaults.set(refreshOnOpen, forKey: Keys.refreshOnOpen) } }
    var autoRefreshEnabled: Bool { didSet { defaults.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) } }
    var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) } }
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
    private var cnyThresholdStorage = 0.0
    private var usdThresholdStorage = 0.0

    var cnyBalanceThreshold: Double {
        get { cnyThresholdStorage }
        set {
            cnyThresholdStorage = max(0, newValue)
            defaults.set(cnyThresholdStorage, forKey: Keys.cnyThreshold)
        }
    }

    var usdBalanceThreshold: Double {
        get { usdThresholdStorage }
        set {
            usdThresholdStorage = max(0, newValue)
            defaults.set(usdThresholdStorage, forKey: Keys.usdThreshold)
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

    var needsNotificationPermission: Bool { notificationStatus == .notDetermined }

    init(
        defaults: UserDefaults = .standard,
        loginItemManager: LoginItemManaging? = nil,
        notificationManager: NotificationAuthorizationManaging? = nil
    ) {
        self.defaults = defaults
        self.loginItemManager = loginItemManager ?? SystemLoginItemManager()
        self.notificationManager = notificationManager ?? SystemNotificationAuthorizationManager()
        launchAtLogin = false
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .system
        glassEffectEnabled = defaults.object(forKey: Keys.glassEffectEnabled) as? Bool ?? false
        refreshOnOpen = defaults.object(forKey: Keys.refreshOnOpen) as? Bool ?? true
        autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? true
        refreshInterval = Self.clampedRefreshInterval(defaults.object(forKey: Keys.refreshInterval) as? TimeInterval ?? 120)
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
        notificationManager.requestAuthorization { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    self.notificationRequestError = nil
                case .failure(let error):
                    self.notificationRequestError = Self.notificationRequestErrorMessage(error)
                }
                self.updateNotificationStatus()
            }
        }
    }

    /// 把系统拒绝翻译成可操作的中文说明。
    /// `UNErrorDomain` code 1 表示系统不允许该进程注册通知（未签名或缺少通知签名 entitlement）。
    private static func notificationRequestErrorMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == UNErrorDomain, error.code == 1 {
            return "系统拒绝注册通知：当前构建没有 Apple 开发者签名，macOS 不允许它发送通知。"
        }
        return "请求通知权限失败：\(error.localizedDescription)"
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

    static let refreshIntervalPresets: [TimeInterval] = [60, 120, 300, 600, 1800]

    private static func clampedRefreshInterval(_ value: TimeInterval) -> TimeInterval {
        refreshIntervalPresets.contains(value) ? value : 120
    }

    private enum Keys {
        static let launchAtLogin = "settings.launchAtLogin"
        static let appearanceMode = "settings.appearanceMode"
        static let glassEffectEnabled = "settings.glassEffectEnabled"
        static let refreshOnOpen = "settings.refreshOnOpen"
        static let autoRefreshEnabled = "settings.autoRefreshEnabled"
        static let refreshInterval = "settings.refreshInterval"
        static let lowBalanceAlerts = "settings.lowBalanceAlerts"
        static let authenticationAlerts = "settings.authenticationAlerts"
        static let serviceErrorAlerts = "settings.serviceErrorAlerts"
        static let cnyThreshold = "settings.cnyBalanceThreshold"
        static let usdThreshold = "settings.usdBalanceThreshold"
    }
}
