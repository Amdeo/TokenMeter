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
    /// 更新检查。放在这里是因为它要在整个 app 生命周期里活着：
    /// 只是把它塞进设置窗口或面板，那些对象一没，Sparkle 的排期也就停了。
    private var update: AppUpdate?
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

        let update = AppUpdate()
        self.update = update

        let controller = MenuBarPanelController(store: store, navigation: navigation)
        controller.onCheckForUpdates = { [weak update] in update?.checkForUpdates() }
        controller.start()
        panelController = controller
        observePanelSettings(settings, controller: controller)

        // 悬浮条的放置由窗口控制器与设置窗口共用：设置窗口里那个「位置」选择器
        // 改的就是它。
        let placement = RailPlacement.restored()
        startRail(store: store, settings: settings, placement: placement)
        startSettings(store: store, settings: settings, placement: placement, panel: controller, update: update)
    }

    /// 常驻悬浮条。
    ///
    /// 与管理面板完全独立：那是点状态栏图标弹出、点外面就收起的面板，
    /// 这是贴在屏幕边上的条。两者共用的只有 `UsageStore` 与设置。
    private func startRail(
        store: UsageStore,
        settings: SettingsStore,
        placement: RailPlacement
    ) {
        let rail = RailWindowController(store: store, settings: settings, placement: placement)

        railMenuActions.onOpenSettings = { [weak self] in self?.settingsController?.show(pane: .general) }
        // 「常显示」就是设置里那个「离开时自动收起」的反面。菜单里说正面：
        // 勾上 = 不收，因为勾选项上写「离开时自动收起」会让人分不清勾了到底收不收。
        railMenuActions.onToggleAlwaysVisible = { settings.railAutoCollapse.toggle() }
        railMenuActions.onMove = { [weak rail] dock in
            rail?.move(to: dock)
        }
        railMenuActions.onQuit = {
            store.stop()
            NSApplication.shared.terminate(nil)
        }
        let actions = railMenuActions
        rail.contextMenu = {
            RailContextMenu.build(placement: placement, settings: settings, actions: actions)
        }

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
        panel: MenuBarPanelController,
        update: AppUpdate
    ) {
        let window = SettingsWindowController(
            store: store,
            settings: settings,
            railPlacement: placement,
            update: update
        )
        panel.onOpenSettings = { [weak window] in window?.show(pane: .general) }
        panel.onAddSubscription = { [weak window] in window?.show(pane: .addSubscription) }
        panel.onEditSubscription = { [weak window] id in
            window?.show(pane: .subscription(id))
        }
        settingsController = window
    }

    /// 设置一变就让悬浮条跟上：开关它、换层级、换空间策略、起停跨屏跟随、按新的尺寸预算重摆。
    ///
    /// **改尺寸的那几项必须在这里**：间距、百分比开关、圆角端都改变条的长宽，
    /// 而窗口 frame 是按条算出来的——不重新摆放，条就会从它被放下的地方漂走。
    ///
    /// `withObservationTracking` 的 onChange 只报**一次**，所以每次回调都要重新注册。
    /// 它在 willSet 时机触发，此时新值还没落进属性，所以真正读值要放到下一轮主线程队列。
    private func observeRailSettings(_ settings: SettingsStore, controller: RailWindowController) {
        withObservationTracking {
            _ = settings.railEnabled
            _ = settings.railAutoCollapse
            _ = settings.railFollowsActiveDisplay
            _ = settings.railHidesInFullScreen
            _ = settings.railSpacing
            _ = settings.railSideShowsPercentages
            _ = settings.railTopShowsPercentages
            _ = settings.railLabelAboveRing
            _ = settings.railUsesRoundEnds
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                controller.settingsChanged()
                self.observeRailSettings(settings, controller: controller)
            }
        }
    }

    /// 「点击图标弹出面板」改了要让面板跟上：关掉时把已经弹出的那个收掉。
    ///
    /// 与悬浮条那份观察同一个套路：`onChange` 只报一次，回调里要重新注册。
    private func observePanelSettings(_ settings: SettingsStore, controller: MenuBarPanelController) {
        withObservationTracking {
            _ = settings.menuBarItemOpensPanel
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                controller.settingsChanged()
                self.observePanelSettings(settings, controller: controller)
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
