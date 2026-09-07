import AppKit
import SwiftUI

@MainActor
final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class MenuBarHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class MenuBarPanelController: NSObject {
    private let store: UsageStore
    private let navigation: PanelNavigationState
    private let panel: MenuBarPanel
    private var statusItem: NSStatusItem?
    private var hostingView: MenuBarHostingView?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var applicationResignObserver: NSObjectProtocol?
    private var panelSize: PanelSize
    private var visibilityGate = PanelVisibilityGate()
    private var isStarted = false

    init(store: UsageStore, navigation: PanelNavigationState) {
        self.store = store
        self.navigation = navigation
        self.panelSize = navigation.panelSize
        self.panel = MenuBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.67percent",
                accessibilityDescription: "TokenMeter"
            )
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown])
            button.toolTip = "TokenMeter"
            button.setAccessibilityLabel("TokenMeter")
        }
        self.statusItem = statusItem
        if let frame = frame(for: panelSize) {
            panel.setFrame(frame, display: false)
        }

        let rootView = AnyView(
            MenuBarView(onPanelSizeChange: { [weak self] size in
                self?.updatePanelSize(size)
            })
            .environment(store)
            .environment(navigation)
        )
        let hostingView = MenuBarHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 14
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        hostingView.frame = panel.contentView?.bounds ?? hostingView.frame
        self.hostingView = hostingView

        installEventHandling()
        updatePanelSize(navigation.panelSize)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        hidePanel()

        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let applicationResignObserver { NotificationCenter.default.removeObserver(applicationResignObserver) }
        screenObserver = nil
        applicationResignObserver = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
        hostingView = nil
        panel.contentView = nil
        store.stop()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.onCancel = { [weak self] in self?.hidePanel() }
    }

    private func installEventHandling() {
        let mouseDownEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) { [weak self] event in
            self?.hideIfClickedOutside()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents) { [weak self] _ in
            self?.hideIfClickedOutside()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCurrentFrame() }
        }
        applicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
    }

    private func updatePanelSize(_ size: PanelSize) {
        panelSize = size
        guard isStarted, panel.isVisible else { return }
        applyCurrentFrame()
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard isStarted else { return }
        panelSize = navigation.panelSize
        guard let frame = frame(for: panelSize) else { return }

        // 先设置最终 frame，再显示窗口；自有面板不会经过系统的二次重摆。
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()

        if visibilityGate.didReceiveDisplayEvent(), store.settings.refreshOnOpen {
            Task { [weak self] in
                guard let self else { return }
                await self.store.refreshAll(source: .panelOpen)
            }
        }
    }

    private func hidePanel() {
        guard panel.isVisible else {
            visibilityGate.didReceiveHiddenEvent()
            return
        }
        panel.orderOut(nil)
        panel.resignKey()
        visibilityGate.didReceiveHiddenEvent()
    }

    private func hideIfClickedOutside() {
        guard panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        if panel.frame.contains(location) || statusButtonFrame?.contains(location) == true { return }
        hidePanel()
    }

    private var statusButtonFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func frame(for size: PanelSize) -> NSRect? {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              let buttonFrame = statusButtonFrame else {
            guard let screen = NSScreen.main else { return nil }
            return PanelFramePositioner.frame(
                contentSize: NSSize(width: size.width, height: size.height),
                screenFrame: screen.visibleFrame,
                anchorX: screen.visibleFrame.midX,
                anchorTop: screen.visibleFrame.maxY
            )
        }

        var screen = buttonWindow.screen
        if screen == nil {
            let buttonCenter = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            for candidate in NSScreen.screens where candidate.frame.contains(buttonCenter) {
                screen = candidate
                break
            }
        }
        screen = screen ?? NSScreen.main
        guard let screen else { return nil }
        return PanelFramePositioner.frame(
            contentSize: NSSize(width: size.width, height: size.height),
            screenFrame: screen.visibleFrame,
            anchorX: buttonFrame.midX,
            anchorTop: buttonFrame.minY
        )
    }

    private func applyCurrentFrame() {
        guard panel.isVisible, let frame = frame(for: panelSize) else { return }
        guard abs(panel.frame.minX - frame.minX) > 0.5
            || abs(panel.frame.minY - frame.minY) > 0.5
            || abs(panel.frame.width - frame.width) > 0.5
            || abs(panel.frame.height - frame.height) > 0.5 else { return }
        panel.setFrame(frame, display: true)
    }
}
