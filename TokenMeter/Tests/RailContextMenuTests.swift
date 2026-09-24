import AppKit
import Testing
import UserNotifications
@testable import TokenMeter

/// 悬浮条右键菜单里有什么、勾在哪一项上。
@MainActor
struct RailContextMenuTests {
    private func makeSettings() -> (SettingsStore, String) {
        let suite = "TokenMeterTests.RailContextMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SettingsStore(defaults: defaults, loginItemManager: NoopLoginItem(), notificationManager: NoopNotifications()), suite)
    }

    private func makeMenu(
        dock: RailDock,
        railAutoCollapse: Bool
    ) -> (menu: NSMenu, settings: SettingsStore, suite: String) {
        let (settings, suite) = makeSettings()
        settings.railAutoCollapse = railAutoCollapse
        let placement = RailPlacement(dock: dock, defaults: UserDefaults(suiteName: suite)!)
        let menu = RailContextMenu.build(
            placement: placement,
            settings: settings,
            actions: RailMenuActions()
        )
        return (menu, settings, suite)
    }

    private func item(_ menu: NSMenu, titled title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    /// 面板的入口是菜单栏图标：条上的菜单里不该再有一个「打开 TokenMeter」。
    @Test
    func menuHasNoPanelEntry() {
        let (menu, _, suite) = makeMenu(dock: .edge(.right), railAutoCollapse: true)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        #expect(item(menu, titled: "打开 TokenMeter") == nil)
        #expect(!menu.items.contains { $0.title.contains("TokenMeter") && $0.title != "退出 TokenMeter" })
        #expect(item(menu, titled: "设置…") != nil)
        #expect(item(menu, titled: "位置")?.submenu != nil)
        #expect(item(menu, titled: "退出 TokenMeter") != nil)
    }

    /// 「常显示」勾的是自动收起的反面：勾上 = 不收。
    @Test
    func alwaysVisibleIsTheOppositeOfAutoCollapse() {
        let (collapsing, _, collapsingSuite) = makeMenu(dock: .edge(.right), railAutoCollapse: true)
        defer { UserDefaults(suiteName: collapsingSuite)?.removePersistentDomain(forName: collapsingSuite) }
        #expect(item(collapsing, titled: "常显示")?.state == .off)

        let (staying, _, stayingSuite) = makeMenu(dock: .edge(.right), railAutoCollapse: false)
        defer { UserDefaults(suiteName: stayingSuite)?.removePersistentDomain(forName: stayingSuite) }
        #expect(item(staying, titled: "常显示")?.state == .on)
    }

    /// 悬浮着的条本来就不收，那一项不该出现——勾了也不生效的开关只会让人以为坏了。
    @Test
    func floatingRailHasNoAlwaysVisibleItem() {
        let (menu, _, suite) = makeMenu(dock: .floating, railAutoCollapse: true)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        #expect(item(menu, titled: "常显示") == nil)
        // 其它项照旧：菜单短了一截，但不能只剩半张。
        #expect(item(menu, titled: "设置…") != nil)
        #expect(item(menu, titled: "位置")?.submenu != nil)
        #expect(item(menu, titled: "退出 TokenMeter") != nil)
    }

    /// 勾选的是当前位置，四项都在。
    @Test
    func positionSubmenuChecksTheCurrentDock() {
        let (menu, _, suite) = makeMenu(dock: .edge(.top), railAutoCollapse: true)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let submenu = item(menu, titled: "位置")?.submenu
        #expect(submenu?.items.count == 4)
        #expect(submenu?.items.first { $0.title == "贴到屏幕顶部" }?.state == .on)
        #expect(submenu?.items.first { $0.title == "自由悬浮" }?.state == .off)
    }
}

private final class NoopLoginItem: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

private final class NoopNotifications: NotificationAuthorizationManaging, @unchecked Sendable {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }

    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        completion(.authorized)
    }
}
