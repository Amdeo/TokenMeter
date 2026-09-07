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
        let settings = SettingsStore()
        let store = UsageStore(settings: settings)
        let navigation = PanelNavigationState()
        if settings.autoRefreshEnabled { store.start() }

        let controller = MenuBarPanelController(store: store, navigation: navigation)
        controller.start()
        panelController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.stop()
    }
}
