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
    }

    init() {
        let store = UsageStore()
        _store = State(initialValue: store)
        store.start()
    }
}

@MainActor
enum SubscriptionEditorWindow {
    private static var window: NSWindow?
    private static var delegate: SubscriptionEditorWindowDelegate?

    static func show(store: UsageStore, subscription: Subscription? = nil) {
        let title = subscription.map { "编辑订阅 · \($0.name)" } ?? "添加订阅"
        let content = AnyView(
            SubscriptionEditorSheet(subscription: subscription, onClose: { close() })
                .environment(store)
        )
        if let window {
            if let controller = window.contentViewController as? NSHostingController<AnyView> {
                controller.rootView = content
            }
            window.title = title
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: content)

        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 640))

        let delegate = SubscriptionEditorWindowDelegate()
        window.delegate = delegate
        self.window = window
        self.delegate = delegate

        window.center()
        window.makeKeyAndOrderFront(nil)
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

private final class SubscriptionEditorWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SubscriptionEditorWindow.handleWindowClosed()
    }
}
