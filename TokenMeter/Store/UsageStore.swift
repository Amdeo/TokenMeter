import Foundation
import Observation
import os

private enum UsageStoreLogger {
    static let logger = Logger(subsystem: "com.tokenmeter.app", category: "usage")
}

enum RefreshSource: Sendable {
    case manual
    case panelOpen
    case background
}

@MainActor
@Observable
final class UsageStore {
    private(set) var subscriptions: [Subscription] = []
    private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    let settings: SettingsStore
    var autoRefreshEnabled: Bool {
        get { settings.autoRefreshEnabled }
        set { settings.autoRefreshEnabled = newValue }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let credentials = CredentialStore()
    private var refreshTask: Task<Void, Never>?
    private let alerts: AlertCoordinating

    private var metadataURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("subscriptions.json")
    }

    init(settings: SettingsStore = SettingsStore(), alerts: AlertCoordinating? = nil) {
        self.settings = settings
        self.alerts = alerts ?? NotificationCoordinator(settings: settings)
        loadSubscriptions()
    }

    var orderedSubscriptions: [Subscription] { subscriptions.sorted { $0.createdAt < $1.createdAt } }

    func add(_ subscription: Subscription) {
        subscriptions.append(subscription)
        saveSubscriptions()
    }

    func remove(_ subscription: Subscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        snapshots.removeValue(forKey: subscription.id)
        alerts.remove(subscriptionID: subscription.id)
        try? credentials.remove(for: subscription.id)
        saveSubscriptions()
    }

    func rename(_ subscription: Subscription, to name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].name = name
        saveSubscriptions()
    }

    func updateAuthMethod(_ subscription: Subscription, to authMethod: Subscription.AuthMethod) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].authMethod = authMethod
        saveSubscriptions()
    }

    func refresh(_ subscription: Subscription, source: RefreshSource = .manual) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefreshAt = .now }
        await fetch(subscription, source: source)
    }

    func refreshAll(source: RefreshSource = .manual) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; lastRefreshAt = .now }
        for subscription in orderedSubscriptions where subscription.isEnabled {
            if Task.isCancelled { return }
            await fetch(subscription, source: source)
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled, autoRefreshEnabled else { continue }
                await refreshAll(source: .background)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func fetch(_ subscription: Subscription, source: RefreshSource) async {
        UsageStoreLogger.logger.debug("fetch started platform=\(subscription.platform.rawValue, privacy: .public)")
        do {
            let snapshot = try await LiveUsageProviders.provider(for: subscription).fetchUsage()
            let previous = snapshots[subscription.id]
            snapshots[subscription.id] = snapshot
            alerts.process(previous: previous, current: snapshot, subscription: subscription, source: source)
        } catch is CancellationError {
            UsageStoreLogger.logger.debug("fetch cancelled platform=\(subscription.platform.rawValue, privacy: .public)")
        } catch {
            if case UsageProviderError.unsupported = error {
                snapshots[subscription.id] = .unsupported(subscription: subscription, message: error.localizedDescription)
                UsageStoreLogger.logger.info("snapshot stored platform=\(subscription.platform.rawValue, privacy: .public) generated=true state=unsupported")
            } else if case UsageProviderError.notConfigured = error {
                let snapshot = UsageSnapshot(subscriptionID: subscription.id, platform: subscription.platform, quotas: [], updatedAt: .now, isDemo: false, errorMessage: error.localizedDescription, state: .notConfigured)
                let previous = snapshots[subscription.id]
                snapshots[subscription.id] = snapshot
                alerts.process(previous: previous, current: snapshot, subscription: subscription, source: source)
                UsageStoreLogger.logger.info("snapshot stored platform=\(subscription.platform.rawValue, privacy: .public) generated=true state=notConfigured")
            } else if case UsageProviderError.authenticationRequired = error {
                let snapshot = UsageSnapshot(subscriptionID: subscription.id, platform: subscription.platform, quotas: [], updatedAt: .now, isDemo: false, errorMessage: error.localizedDescription, state: .authenticationRequired)
                let previous = snapshots[subscription.id]
                snapshots[subscription.id] = snapshot
                alerts.process(previous: previous, current: snapshot, subscription: subscription, source: source)
                UsageStoreLogger.logger.info("snapshot stored platform=\(subscription.platform.rawValue, privacy: .public) generated=true state=authenticationRequired")
            } else {
                let snapshot = UsageSnapshot.failure(subscription: subscription, message: error.localizedDescription)
                let previous = snapshots[subscription.id]
                snapshots[subscription.id] = snapshot
                alerts.process(previous: previous, current: snapshot, subscription: subscription, source: source)
                UsageStoreLogger.logger.error("""
                    snapshot stored \
                    platform=\(subscription.platform.rawValue, privacy: .public) \
                    generated=true state=error \
                    errorClass=\(Self.errorClass(error), privacy: .public)
                    """)
            }
        }
    }

    private static func errorClass(_ error: Error) -> String {
        switch error {
        case UsageProviderError.httpStatus: return "httpStatus"
        case UsageProviderError.invalidJSON: return "invalidJSON"
        case UsageProviderError.requestFailed: return "requestFailed"
        case UsageProviderError.invalidResponse: return "invalidResponse"
        case UsageProviderError.authenticationRequired: return "authenticationRequired"
        case UsageProviderError.notConfigured: return "notConfigured"
        case UsageProviderError.unsupported: return "unsupported"
        default: return "other"
        }
    }

    private func loadSubscriptions() {
        guard let data = try? Data(contentsOf: metadataURL), let loaded = try? decoder.decode([Subscription].self, from: data) else { return }
        subscriptions = loaded
    }

    private func saveSubscriptions() {
        do {
            let directory = metadataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(subscriptions).write(to: metadataURL, options: .atomic)
        } catch {
        }
    }
}
