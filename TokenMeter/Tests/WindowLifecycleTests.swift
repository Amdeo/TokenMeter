import AppKit
import Foundation
import Testing
import UserNotifications
@testable import TokenMeter

/// 窗口生命周期测试使用独立 defaults、临时元数据和无副作用的系统服务替身。
@Suite(.serialized)
@MainActor
struct WindowLifecycleTests {
    @Test
    func panelBuildsContentOnlyWhileVisible() async throws {
        let fixture = try PanelLifecycleFixture()
        defer { fixture.remove() }

        let controller = MenuBarPanelController(
            store: fixture.store,
            navigation: PanelNavigationState(defaults: fixture.defaults)
        )
        controller.start()
        defer { controller.stop() }

        #expect(controller.panelContentView == nil)
        controller.showPanel()
        let weakContent: WeakObjectBox
        do {
            let content = try #require(controller.panelContentView)
            weakContent = WeakObjectBox(content)
        }

        controller.hidePanel()

        #expect(controller.panelContentView == nil)
        try await waitForRelease(weakContent)
    }

    @Test
    func closingSettingsReleasesWindowAndKeepsDraftAndPosition() async throws {
        let suite = "TokenMeterTests.WindowLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            defaults: defaults,
            loginItemManager: LifecycleLoginItemManager(),
            notificationManager: LifecycleNotificationManager()
        )
        let placement = RailPlacement(defaults: defaults)
        let controller = SettingsWindowController(
            store: UsageStore(settings: settings, metadataURL: defaultsFixtureURL()),
            settings: settings,
            railPlacement: placement,
            update: AppUpdate()
        )
        let subscription = Subscription(providerID: .kimi, name: "测试订阅", authMethodID: .apiKey)

        controller.show()
        controller.navigation.edit(subscription)
        controller.navigation.subscriptionDraft?.name = "未保存名称"
        let draft = try #require(controller.navigation.subscriptionDraft)
        let frame = NSRect(x: 140, y: 180, width: 920, height: 660)
        controller.window?.setFrame(frame, display: false)
        let weakContent = WeakObjectBox(try #require(controller.window?.contentView))

        controller.window?.close()

        #expect(controller.window == nil)
        try await waitForRelease(weakContent)
        #expect(controller.navigation.subscriptionDraft === draft)
        #expect(controller.navigation.subscriptionDraft?.name == "未保存名称")

        controller.show()
        let restored = try #require(controller.window)
        #expect(abs(restored.frame.minX - frame.minX) < 0.5)
        #expect(abs(restored.frame.minY - frame.minY) < 0.5)
        #expect(abs(restored.frame.width - frame.width) < 0.5)
        #expect(abs(restored.frame.height - frame.height) < 0.5)
        restored.close()
    }
}

private func waitForRelease(_ box: WeakObjectBox) async throws {
    for _ in 0..<20 {
        if box.value == nil { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(box.value == nil)
}

@MainActor
private final class PanelLifecycleFixture {
    let directory: URL
    let defaults: UserDefaults
    let defaultsSuite: String
    let store: UsageStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterWindowLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuite = "TokenMeterTests.PanelLifecycle.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        let settings = SettingsStore(
            defaults: defaults,
            loginItemManager: LifecycleLoginItemManager(),
            notificationManager: LifecycleNotificationManager()
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
        defaults.removePersistentDomain(forName: defaultsSuite)
    }
}

private func defaultsFixtureURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenMeterWindowSettings-\(UUID().uuidString).json")
}

private final class WeakObjectBox {
    weak var value: AnyObject?

    init(_ value: AnyObject) { self.value = value }
}

private final class LifecycleLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
}

private final class LifecycleNotificationManager: NotificationAuthorizationManaging, @unchecked Sendable {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        completion(.authorized)
    }
}
