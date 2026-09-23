import AppKit
import SwiftUI

@main
struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(TokenMeterAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class TokenMeterAppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: MenuBarPanelController?
    private var railController: RailWindowController?
    private var settingsController: SettingsWindowController?
    /// 悬浮条右键菜单的目标。菜单项持的是 target/action 对而不是闭包，
    /// 所以这个对象必须在菜单的生命周期之外活着。
    private let railMenuActions = RailMenuActions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Swift Testing loads this App target as its host process. Do not touch
        // production defaults, credentials, stores, or windows in that host.
        guard !Self.isRunningTests else { return }

        let settings = SettingsStore()
        // 概览面板不再显示通知授权入口，启动时主动请求一次。
        settings.requestNotificationsIfNeeded()
        let store = UsageStore(settings: settings)
        let navigation = PanelNavigationState()
        if settings.autoRefreshEnabled { store.start() }

        let controller = MenuBarPanelController(store: store, navigation: navigation)
        controller.start()
        panelController = controller

        // 悬浮条的放置由窗口控制器与设置窗口共用：设置窗口里那个「位置」选择器
        // 改的就是它。
        let placement = RailPlacement.restored()
        startRail(store: store, settings: settings, placement: placement, panel: controller)
        startSettings(store: store, settings: settings, placement: placement, panel: controller)
    }

    /// 常驻悬浮条。
    ///
    /// 与管理面板完全独立：那是点状态栏图标弹出、点外面就收起的面板，
    /// 这是贴在屏幕边上的条。两者共用的只有 `UsageStore` 与设置。
    private func startRail(
        store: UsageStore,
        settings: SettingsStore,
        placement: RailPlacement,
        panel: MenuBarPanelController
    ) {
        let rail = RailWindowController(store: store, settings: settings, placement: placement)

        railMenuActions.onOpenPanel = { [weak panel] in panel?.present() }
        railMenuActions.onOpenSettings = { [weak self] in self?.settingsController?.show(pane: .general) }
        railMenuActions.onMove = { [weak rail] dock in
            rail?.move(to: dock)
        }
        railMenuActions.onQuit = {
            store.stop()
            NSApplication.shared.terminate(nil)
        }
        rail.contextMenu = { [weak self] in self?.railMenu(placement) ?? NSMenu() }

        rail.start()
        railController = rail

        observeRailSettings(settings, controller: rail)
    }

    /// 独立设置窗口。
    ///
    /// 所有入口都通到这里：面板头部的齿轮、面板里的「添加订阅」与订阅卡片、
    /// 状态栏右键菜单的「设置…」与「添加订阅」、悬浮条右键菜单的「设置…」。
    /// 面板自己只剩概览一页，别的事都由窗口承担。
    private func startSettings(
        store: UsageStore,
        settings: SettingsStore,
        placement: RailPlacement,
        panel: MenuBarPanelController
    ) {
        let window = SettingsWindowController(store: store, settings: settings, railPlacement: placement)
        panel.onOpenSettings = { [weak window] in window?.show(pane: .general) }
        panel.onAddSubscription = { [weak window] in window?.show(pane: .addSubscription) }
        panel.onEditSubscription = { [weak window] id in
            window?.show(pane: .subscription(id))
        }
        settingsController = window
    }

    private func railMenu(_ placement: RailPlacement) -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "打开 TokenMeter", action: #selector(RailMenuActions.openPanel), keyEquivalent: "")
        open.target = railMenuActions
        menu.addItem(open)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(RailMenuActions.openSettings), keyEquivalent: "")
        settingsItem.target = railMenuActions
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 位置放在菜单里而不是只放设置页里：它作用的对象就是这条条本身，
        // 而拖动已经能做同一件事，菜单只是给一个说得清楚的做法。
        let position = NSMenuItem(title: "位置", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let options: [(String, RailDock, Selector)] = [
            ("贴到屏幕左侧", .edge(.left), #selector(RailMenuActions.dockLeft)),
            ("贴到屏幕右侧", .edge(.right), #selector(RailMenuActions.dockRight)),
            ("贴到屏幕顶部", .edge(.top), #selector(RailMenuActions.dockTop)),
            ("自由悬浮", .floating, #selector(RailMenuActions.float)),
        ]
        for (title, dock, action) in options {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = railMenuActions
            item.state = placement.dock == dock ? .on : .off
            submenu.addItem(item)
        }
        position.submenu = submenu
        menu.addItem(position)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 TokenMeter", action: #selector(RailMenuActions.quit), keyEquivalent: "")
        quit.target = railMenuActions
        menu.addItem(quit)

        return menu
    }

    /// 设置一变就让悬浮条跟上：开关它、换层级、换空间策略、起停跨屏跟随。
    ///
    /// `withObservationTracking` 的 onChange 只报**一次**，所以每次回调都要重新注册。
    /// 它在 willSet 时机触发，此时新值还没落进属性，所以真正读值要放到下一轮主线程队列。
    private func observeRailSettings(_ settings: SettingsStore, controller: RailWindowController) {
        withObservationTracking {
            _ = settings.railEnabled
            _ = settings.railAutoCollapse
            _ = settings.railFollowsActiveDisplay
            _ = settings.railHidesInFullScreen
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                controller.settingsChanged()
                self.observeRailSettings(settings, controller: controller)
            }
        }
    }

    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        railController?.stop()
        panelController?.stop()
    }
}
