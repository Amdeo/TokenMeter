import AppKit
import Foundation
import Testing
import UserNotifications
@testable import TokenMeter

/// 悬浮条内容生命周期回归：隐藏时不保留 SwiftUI 树，订阅变化时按需恢复。
@Suite(.serialized)
@MainActor
struct RailPerformanceTests {
    @Test
    func disabledRailDoesNotInstallHostedContent() throws {
        let fixture = try RailPerformanceFixture()
        defer { fixture.remove() }

        fixture.settings.railEnabled = false
        let controller = RailWindowController(
            store: fixture.store,
            settings: fixture.settings,
            placement: RailPlacement(defaults: fixture.defaults)
        )
        controller.start()
        defer { controller.stop() }

        #expect(controller.hostedContentView == nil)
    }

    @Test
    func hidingAndShowingRailReleasesAndRecreatesContent() async throws {
        let fixture = try RailPerformanceFixture()
        defer { fixture.remove() }
        fixture.settings.railEnabled = true
        let subscription = Subscription(providerID: .kimi, name: "性能测试", authMethodID: .apiKey)
        fixture.store.add(subscription)

        let controller = RailWindowController(
            store: fixture.store,
            settings: fixture.settings,
            placement: RailPlacement(defaults: fixture.defaults)
        )
        controller.start()
        defer { controller.stop() }
        #expect(controller.hostedContentView != nil)
        let weakHost = WeakRailObjectBox(try #require(controller.hostedContentView))

        controller.toggle()
        try await waitUntil { controller.hostedContentView == nil && weakHost.value == nil }
        #expect(controller.hostedContentView == nil)
        #expect(weakHost.value == nil)

        controller.toggle()
        try await waitUntil { controller.hostedContentView != nil }
        #expect(controller.hostedContentView != nil)
    }

    @Test
    func removingLastRailSubscriptionReleasesContentAndAddingOneRestoresIt() async throws {
        let fixture = try RailPerformanceFixture()
        defer { fixture.remove() }
        fixture.settings.railEnabled = true
        let subscription = Subscription(providerID: .kimi, name: "性能测试", authMethodID: .apiKey)
        fixture.store.add(subscription)

        let controller = RailWindowController(
            store: fixture.store,
            settings: fixture.settings,
            placement: RailPlacement(defaults: fixture.defaults)
        )
        controller.start()
        defer { controller.stop() }
        #expect(controller.hostedContentView != nil)

        fixture.store.remove(subscription)
        try await waitUntil { controller.hostedContentView == nil }
        #expect(controller.hostedContentView == nil)

        fixture.store.add(Subscription(providerID: .kimi, name: "重新添加", authMethodID: .apiKey))
        try await waitUntil { controller.hostedContentView != nil }
        #expect(controller.hostedContentView != nil)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<50 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private final class WeakRailObjectBox {
    weak var value: AnyObject?

    init(_ value: AnyObject) { self.value = value }
}

@MainActor
private final class RailPerformanceFixture {
    let directory: URL
    let defaults: UserDefaults
    let suiteName: String
    let settings: SettingsStore
    let store: UsageStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterRailPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "TokenMeterTests.RailPerformance.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = SettingsStore(
            defaults: defaults,
            loginItemManager: RailPerformanceLoginItemManager(),
            notificationManager: RailPerformanceNotificationManager()
        )
        settings.refreshOnOpen = false
        store = UsageStore(
            settings: settings,
            metadataURL: directory.appendingPathComponent("subscriptions.json"),
            credentialStore: CredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class RailPerformanceLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
}

private final class RailPerformanceNotificationManager: NotificationAuthorizationManaging, @unchecked Sendable {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        completion(.authorized)
    }
}
