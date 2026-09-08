import Foundation
import UserNotifications

struct AlertEvaluation: Sendable, Equatable {
    enum Kind: String, Sendable { case lowBalance, authentication, serviceError }
    let kind: Kind
    let key: String
    let title: String
    let body: String
}

protocol AlertDelivery: AnyObject {
    func deliver(_ alert: AlertEvaluation)
}

final class UserNotificationDelivery: AlertDelivery {
    func deliver(_ alert: AlertEvaluation) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

struct AlertSettings: Sendable {
    var lowBalanceAlerts = true
    var authenticationAlerts = true
    var serviceErrorAlerts = false
    var cnyThreshold = 5.0
    var usdThreshold = 1.0

    init() {}

    @MainActor
    init(settings: SettingsStore) {
        lowBalanceAlerts = settings.lowBalanceAlerts
        authenticationAlerts = settings.authenticationAlerts
        serviceErrorAlerts = settings.serviceErrorAlerts
        cnyThreshold = settings.cnyBalanceThreshold
        usdThreshold = settings.usdBalanceThreshold
    }
}

/// Stateful, deterministic alert rules. Ledger values contain only state and timestamps.
final class AlertEvaluator {
    private struct Ledger: Codable {
        var active = false
        var backgroundFailures = 0
        var lastServiceAlertAt: Date?
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let prefix = "alerts.ledger."
    private var ledger: [String: Ledger] = [:]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        if let data = defaults.data(forKey: "alerts.ledger") {
            ledger = (try? JSONDecoder().decode([String: Ledger].self, from: data)) ?? [:]
        }
    }

    func evaluate(previous: UsageSnapshot?, current: UsageSnapshot, subscription: Subscription, providerName: String? = nil, source: RefreshSource, settings: AlertSettings) -> [AlertEvaluation] {
        var alerts: [AlertEvaluation] = []
        let realtime = current.state == .realtime
        let resolvedProviderName = providerName ?? subscription.providerID.rawValue
        let balanceQuotas = current.quotas.filter { $0.kind == .balance && $0.unit.isCurrency }
        for quota in balanceQuotas {
            let currency = quota.unit.label ?? ""
            guard let threshold = threshold(for: currency, settings: settings) else { continue }
            // 同一订阅可能同时有多个同币种余额（如 Kimi 回退的可用/代金券/现金余额），
            // key 必须带上额度名，否则各余额会互相覆盖 ledger 状态，导致提醒重复或漏发。
            let key = ledgerKey(subscription.id, "lowBalance", "\(currency)#\(quota.name)")
            var item = read(key)
            if realtime && quota.remaining / quota.unit.displayScale <= threshold {
                if !item.active && settings.lowBalanceAlerts {
                    alerts.append(AlertEvaluation(kind: .lowBalance, key: key, title: "余额偏低", body: "\(resolvedProviderName) 的 \(currency) 余额已低于你设置的阈值。"))
                }
                item.active = true
            } else if quota.remaining / quota.unit.displayScale > threshold {
                item.active = false
            }
            write(item, key: key)
        }

        let authKey = ledgerKey(subscription.id, "authentication", "status")
        var auth = read(authKey)
        if current.state == .authenticationRequired {
            if !auth.active && settings.authenticationAlerts {
                alerts.append(AlertEvaluation(kind: .authentication, key: authKey, title: "需要重新认证 · \(subscription.name)", body: "\(resolvedProviderName) 认证已失效，请重新连接。"))
            }
            auth.active = true
        } else if realtime {
            auth.active = false
        }
        write(auth, key: authKey)

        let errorKey = ledgerKey(subscription.id, "serviceError", "status")
        var error = read(errorKey)
        if current.state == .realtime {
            error.backgroundFailures = 0
            error.lastServiceAlertAt = nil
            error.active = false
        } else if source == .background && current.state == .error {
            error.backgroundFailures += 1
            let cooled = error.lastServiceAlertAt.map { now().timeIntervalSince($0) >= 3600 } ?? true
            // A cooled alert opens a new notification window. Keep counting only
            // inside the current window so a long outage can notify again hourly.
            if cooled { error.active = false }
            if error.backgroundFailures >= 2 && !error.active && cooled && settings.serviceErrorAlerts {
                alerts.append(AlertEvaluation(kind: .serviceError, key: errorKey, title: "服务暂时不可用 · \(subscription.name)", body: "\(resolvedProviderName) 连续刷新失败，请稍后重试。"))
                error.active = true
                error.lastServiceAlertAt = now()
            }
        }
        write(error, key: errorKey)
        return alerts
    }

    func clear(subscriptionID: UUID) {
        let prefix = "\(self.prefix)\(subscriptionID.uuidString)."
        ledger.keys.filter { $0.hasPrefix(prefix) }.forEach { ledger.removeValue(forKey: $0) }
        persist()
    }

    private func threshold(for currency: String, settings: AlertSettings) -> Double? {
        switch currency.uppercased() {
        case "CNY": settings.cnyThreshold
        case "USD": settings.usdThreshold
        default: nil
        }
    }

    private func ledgerKey(_ id: UUID, _ kind: String, _ semantic: String) -> String { "\(prefix)\(id.uuidString).\(kind).\(semantic)" }
    private func read(_ key: String) -> Ledger { ledger[key] ?? Ledger() }
    private func write(_ value: Ledger, key: String) { ledger[key] = value; persist() }
    private func persist() { defaults.set(try? JSONEncoder().encode(ledger), forKey: "alerts.ledger") }
}

@MainActor
protocol AlertCoordinating: AnyObject {
    func process(previous: UsageSnapshot?, current: UsageSnapshot, subscription: Subscription, source: RefreshSource)
    func remove(subscriptionID: UUID)
}

@MainActor
final class NotificationCoordinator: AlertCoordinating {
    private let settings: SettingsStore
    private let evaluator: AlertEvaluator
    private let delivery: AlertDelivery

    init(settings: SettingsStore, evaluator: AlertEvaluator = AlertEvaluator(), delivery: AlertDelivery = UserNotificationDelivery()) {
        self.settings = settings
        self.evaluator = evaluator
        self.delivery = delivery
    }

    func process(previous: UsageSnapshot?, current: UsageSnapshot, subscription: Subscription, source: RefreshSource) {
        let providerName = ProviderRegistry.definition(for: subscription.providerID)?.metadata.displayName
            ?? subscription.providerID.rawValue
        let alerts = evaluator.evaluate(previous: previous, current: current, subscription: subscription, providerName: providerName, source: source, settings: AlertSettings(settings: settings))
        alerts.forEach(delivery.deliver)
    }

    func remove(subscriptionID: UUID) { evaluator.clear(subscriptionID: subscriptionID) }
}
