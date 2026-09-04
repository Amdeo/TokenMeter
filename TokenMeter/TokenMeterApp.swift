import SwiftUI
import AppKit

@main
struct TokenMeterApp: App {
    @State private var store: UsageStore

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            Label("TokenMeter", systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)

        Window("我的订阅", id: "details") {
            DetailView()
                .environment(store)
        }
        .defaultSize(width: 820, height: 700)
        .windowResizability(.contentSize)
    }

    init() {
        let store = UsageStore()
        _store = State(initialValue: store)
        store.start()
    }
}

@MainActor
enum AddSubscriptionWindow {
    private static var window: NSWindow?
    private static var delegate: AddSubscriptionWindowDelegate?

    static func show(store: UsageStore, editingSubscription: Subscription? = nil) {
        if let window {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = AddSubscriptionSheet(editingSubscription: editingSubscription, onClose: { close() })
        let controller = NSHostingController(rootView: content.environment(store))

        let window = NSWindow(contentViewController: controller)
        window.title = editingSubscription == nil ? "添加订阅" : "更新凭证"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 640))

        let delegate = AddSubscriptionWindowDelegate()
        window.delegate = delegate
        self.window = window
        self.delegate = delegate

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { window.center() }
    }

    static func close() {
        window?.close()
        window = nil
        delegate = nil
    }

    fileprivate static func handleWindowClosed() {
        window = nil
        delegate = nil
    }
}

private final class AddSubscriptionWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AddSubscriptionWindow.handleWindowClosed()
    }
}
