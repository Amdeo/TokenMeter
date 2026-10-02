import Foundation
import Testing
import UserNotifications
@testable import TokenMeter

@MainActor
struct BackgroundRefreshTests {
    @Test
    func settingsControlRefreshWithoutAMenuPanel() async throws {
        let fixture = try BackgroundRefreshFixture()
        defer { fixture.remove() }
        let settings = fixture.makeSettings()
        settings.autoRefreshEnabled = false
        settings.refreshInterval = 0.02
        let counter = BackgroundFetchCounter()
        let store = fixture.makeStore(settings: settings, counter: counter)
        store.add(Subscription(providerID: .deepSeek, name: "Test", authMethodID: .apiKey))
        store.start()
        defer { store.stop() }

        try await Task.sleep(for: .milliseconds(60))
        #expect(await counter.value == 0)

        settings.autoRefreshEnabled = true
        try await waitFor { await counter.value > 0 }
        settings.autoRefreshEnabled = false
        try await Task.sleep(for: .milliseconds(60))
        let stoppedCount = await counter.value
        try await Task.sleep(for: .milliseconds(80))
        #expect(await counter.value == stoppedCount)

        settings.autoRefreshEnabled = true
        try await waitFor { await counter.value > stoppedCount }
        store.stop()
        settings.autoRefreshEnabled = false
        settings.autoRefreshEnabled = true
        try await Task.sleep(for: .milliseconds(60))
        let explicitlyStoppedCount = await counter.value
        try await Task.sleep(for: .milliseconds(80))
        #expect(await counter.value == explicitlyStoppedCount)

        store.start()
        try await waitFor { await counter.value > explicitlyStoppedCount }
    }

    @Test
    func sleepingRefreshLoopDoesNotRetainTheStore() async throws {
        let fixture = try BackgroundRefreshFixture()
        defer { fixture.remove() }
        let settings = fixture.makeSettings()
        let counter = BackgroundFetchCounter()
        var store: UsageStore? = fixture.makeStore(settings: settings, counter: counter)
        let subscription = Subscription(providerID: .deepSeek, name: "Test", authMethodID: .apiKey)
        store?.add(subscription)
        weak var releasedStore = store
        store?.start()
        try await waitFor { store?.snapshots[subscription.id] != nil && store?.isRefreshing == false }

        store = nil
        #expect(releasedStore == nil, "后台循环不能跨越刷新间隔持有 store")
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), "后台刷新未在期限内完成")
    }
}

private actor BackgroundFetchCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct BackgroundTestProvider: UsageProvider {
    let subscription: Subscription
    let counter: BackgroundFetchCounter

    func fetchUsage() async throws -> UsageSnapshot {
        await counter.increment()
        return .realtime(subscription: subscription, quotas: [])
    }
}

@MainActor
private final class BackgroundRefreshFixture {
    private let suite = "TokenMeterTests.BackgroundRefresh.\(UUID().uuidString)"
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenMeterBackgroundRefresh-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeSettings() -> SettingsStore {
        SettingsStore(
            defaults: UserDefaults(suiteName: suite)!,
            loginItemManager: BackgroundLoginItems(),
            notificationManager: BackgroundNotifications()
        )
    }

    func makeStore(settings: SettingsStore, counter: BackgroundFetchCounter) -> UsageStore {
        UsageStore(
            settings: settings,
            metadataURL: directory.appendingPathComponent("subscriptions.json"),
            providerFactory: { subscription, _ in
                BackgroundTestProvider(subscription: subscription, counter: counter)
            }
        )
    }

    func remove() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct BackgroundLoginItems: LoginItemManaging {
    var status: LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

private struct BackgroundNotifications: NotificationAuthorizationManaging {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        completion(.denied)
    }
}
