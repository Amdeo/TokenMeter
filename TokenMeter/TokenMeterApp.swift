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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Swift Testing loads this App target as its host process. Do not touch
        // production defaults, credentials, stores, or windows in that host.
        guard !Self.isRunningTests else { return }

        let settings = SettingsStore()
        let store = UsageStore(settings: settings)
        let navigation = PanelNavigationState()
        if settings.autoRefreshEnabled { store.start() }

        let controller = MenuBarPanelController(store: store, navigation: navigation)
        controller.start()
        panelController = controller
    }

    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.stop()
    }
}
