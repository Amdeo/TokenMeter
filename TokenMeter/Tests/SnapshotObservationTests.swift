import AppKit
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import TokenMeter

/// 概览列表的快照读取位置回归。
///
/// 快照必须在单行视图（`SubscriptionRowCard`）自己的 body 里读取。读在 `MenuBarView` 的 body
/// 上时，任何一次快照写入都会让整个面板失效：列表理想高度重算、`List` 与表头一起重建，
/// 还会带出一次行高测量 → 改窗口 frame 的布局级联。
///
/// 本用例通过引用 `SubscriptionRowCard` 把读取位置钉住：把读取挪回父视图（或删掉这一层）
/// 会直接编译失败；把读取留在这一层则由下面的观测断言保证。
@MainActor
struct SnapshotObservationTests {
    @Test
    func rowCardReadsItsSnapshotFromTheStore() async throws {
        let fixture = try SnapshotObservationFixture()
        defer { fixture.remove() }
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        let store = fixture.makeStore()
        store.add(subscription)

        let invalidated = InvalidationFlag()
        withObservationTracking {
            _ = SubscriptionRowCard(
                store: store,
                subscription: subscription,
                onEdit: {},
                isReordering: false
            ).body
        } onChange: {
            invalidated.value = true
        }

        store.refresh(subscription)
        var spins = 0
        while store.snapshots[subscription.id] == nil, spins < 10_000 {
            spins += 1
            await Task.yield()
        }

        #expect(store.snapshots[subscription.id] != nil, "刷新未写入快照，用例前提不成立")
        #expect(invalidated.value, "单行视图必须自己订阅 store.snapshots")
    }
}

/// `withObservationTracking(onChange:)` 的闭包是 `@Sendable`，跨并发域回写只能走受检容器；
/// 用例全程在主 actor 上串行执行。
private final class InvalidationFlag: @unchecked Sendable {
    var value = false
}

private struct FixedSnapshotProvider: UsageProvider {
    let subscription: Subscription

    func fetchUsage() async throws -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(
                name: "API 余额", used: 18.42, limit: 100, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])
    }
}

private final class SnapshotLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

private final class SnapshotNotificationManager: NotificationAuthorizationManaging, @unchecked Sendable {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        completion(.authorized)
    }
}

@MainActor
private final class SnapshotObservationFixture {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenMeterSnapshotTests-\(UUID().uuidString)", isDirectory: true)
    private let suite = "TokenMeterSnapshotTests.\(UUID().uuidString)"

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeStore() -> UsageStore {
        UsageStore(
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: suite)!,
                loginItemManager: SnapshotLoginItemManager(),
                notificationManager: SnapshotNotificationManager()
            ),
            metadataURL: directory.appendingPathComponent("subscriptions.json"),
            credentialStore: CredentialStore(fileURL: directory.appendingPathComponent("credentials.json")),
            providerFactory: { subscription, _ in FixedSnapshotProvider(subscription: subscription) }
        )
    }

    func remove() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
