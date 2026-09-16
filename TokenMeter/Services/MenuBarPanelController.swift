import AppKit
import SwiftUI

/// 排序拖拽边缘提示。完全由 AppKit 绘制：拖动期间若改 SwiftUI 状态，
/// 会触发 List 重建并杀死正在进行的原生拖放会话。
@MainActor
private final class SubscriptionEdgeHintView: NSView {
    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let accent = NSColor(TM.accent)
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 1

        textLabel.font = .systemFont(ofSize: 11, weight: .medium)
        textLabel.textColor = .labelColor
        iconView.contentTintColor = .labelColor

        let stack = NSStackView(views: [iconView, textLabel])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, symbol: String) {
        textLabel.stringValue = text
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
    }
}

@MainActor
final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// 由 MenuBarView 在切换排序模式时同步，拖动期间不回调 SwiftUI。
    var isReordering = false

    private let hintView = SubscriptionEdgeHintView()
    private weak var dragTable: NSTableView?
    private var dragTimer: Timer?
    private var placedHideTimer: Timer?
    private var pasteboardChangeCount = 0
    private var isDraggingSubscription = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            cancelDragFeedback()
            super.sendEvent(event)
            onCancel?()
            return
        }
        if event.type == .leftMouseDown {
            cancelDragFeedback()
            if isReordering, let table = tableRow(at: event.locationInWindow) {
                dragTable = table
                pasteboardChangeCount = NSPasteboard(name: .drag).changeCount
                // 原生 List 拖放跑嵌套事件循环并吞掉鼠标事件；定时器挂在
                // eventTracking 模式，让它在拖动期间持续更新提示。
                let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateDragFeedback() }
                }
                dragTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
        }
        if event.type == .leftMouseDragged, dragTimer != nil {
            contentView?.autoscroll(with: event)
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp { updateDragFeedback() }
    }

    override func orderOut(_ sender: Any?) {
        cancelDragFeedback()
        super.orderOut(sender)
    }

    private func updateDragFeedback() {
        guard dragTimer != nil else { return }
        guard isVisible, isReordering, let table = dragTable, table.window === self else {
            cancelDragFeedback()
            return
        }
        if !isDraggingSubscription,
           NSPasteboard(name: .drag).changeCount != pasteboardChangeCount {
            isDraggingSubscription = true
        }

        // 屏幕坐标自下而上，与 NSHostingView.isFlipped 无关。
        let isTopHalf = NSEvent.mouseLocation.y >= frame.midY
        if NSEvent.pressedMouseButtons & 1 == 0 {
            let screenPoint = NSEvent.mouseLocation
            let point = table.convert(convertPoint(fromScreen: screenPoint), from: nil)
            let inTable = table.visibleRect.contains(point)
            let didPlace = isDraggingSubscription && inTable
            cancelDragFeedback()
            guard didPlace else { return }
            showHint(text: "已放置", symbol: "checkmark.circle.fill", atTopEdge: isTopHalf, for: table)
            let hideTimer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hintView.isHidden = true }
            }
            placedHideTimer = hideTimer
            RunLoop.main.add(hideTimer, forMode: .common)
            return
        }

        guard isDraggingSubscription else { return }
        let atTop = table.visibleRect.minY <= 0.5
        let atBottom = table.visibleRect.maxY >= table.frame.height - 0.5
        if isTopHalf, !atTop {
            showHint(text: "继续向上滚动", symbol: "arrow.up", atTopEdge: true, for: table)
        } else if !isTopHalf, !atBottom {
            showHint(text: "继续向下滚动", symbol: "arrow.down", atTopEdge: false, for: table)
        } else {
            hintView.isHidden = true
        }
    }

    private func showHint(text: String, symbol: String, atTopEdge: Bool, for table: NSTableView) {
        guard let contentView, let scrollView = table.enclosingScrollView else { return }
        contentView.addSubview(hintView, positioned: .above, relativeTo: nil)
        hintView.configure(text: text, symbol: symbol)

        let scrollFrame = scrollView.convert(scrollView.bounds, to: nil)
        let windowRect = CGRect(
            x: scrollFrame.minX + 4,
            y: atTopEdge ? scrollFrame.maxY - 38 : scrollFrame.minY + 4,
            width: scrollFrame.width - 8,
            height: 34
        )
        hintView.frame = contentView.convert(windowRect, from: nil)
        hintView.isHidden = false
    }

    private func cancelDragFeedback() {
        dragTimer?.invalidate()
        dragTimer = nil
        placedHideTimer?.invalidate()
        placedHideTimer = nil
        dragTable = nil
        isDraggingSubscription = false
        hintView.isHidden = true
    }

    private func tableRow(at windowPoint: NSPoint) -> NSTableView? {
        guard let contentView else { return nil }
        var view = contentView.hitTest(windowPoint)
        while let current = view {
            if let table = current as? NSTableView {
                let point = table.convert(windowPoint, from: nil)
                return table.visibleRect.contains(point) && table.row(at: point) >= 0 ? table : nil
            }
            view = current.superview
        }
        return nil
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
    private var secondaryClickMonitor: Any?
    private var visibilityGate = PanelVisibilityGate()
    private var isStarted = false

    init(store: UsageStore, navigation: PanelNavigationState) {
        self.store = store
        self.navigation = navigation
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
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "TokenMeter"
            button.setAccessibilityLabel("TokenMeter")
        }
        self.statusItem = statusItem
        updateVisibleHeightLimit()
        if let frame = frame(for: navigation.displayedSize) {
            panel.setFrame(frame, display: false)
        }

        let rootView = AnyView(
            MenuBarView(
                onPanelSizeChange: { [weak self] _ in
                    self?.refreshPanelGeometry()
                },
                onReorderModeChange: { [weak self] reordering in
                    self?.panel.isReordering = reordering
                }
            )
            .environment(store)
            .environment(navigation)
        )
        let container = PanelContainerView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.autoresizingMask = [.width, .height]

        let hostingView = MenuBarHostingView(rootView: rootView)
        // 宿主视图尺寸只由容器决定，且必须是结构性的：过去用一次赋值 + autoresizing 同步，
        // 而 autoresizing 只按增量调整 frame —— 宿主一旦被外力改小（平台视图插约束、布局引擎
        // 重解、被跳过的布局），错位就会一直保留（窗口在手动高度下不再变化），表现为内容比
        // 窗口矮一截且贴底。四边约束让布局引擎在每次布局里把宿主拉回容器尺寸。
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container
        hostingView.frame = container.bounds
        container.hostedContentView = hostingView
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.hostingView = hostingView

        installEventHandling()
        refreshPanelGeometry()
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
        if let secondaryClickMonitor { NSEvent.removeMonitor(secondaryClickMonitor) }
        secondaryClickMonitor = nil
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
        // 状态栏按钮上的右击直接弹菜单：不依赖按钮 action 里对事件类型的判断，
        // 因为不同输入设备（真右键 / control-左击 / 鼠标工具）送到的事件形态不同。
        // 命中按钮时吞掉事件，避免按钮再走一次左键逻辑。
        secondaryClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, self.statusButtonFrame?.contains(NSEvent.mouseLocation) == true else { return event }
            self.presentContextMenu()
            return nil
        }
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
            MainActor.assumeIsolated { self?.refreshPanelGeometry() }
        }
        applicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
    }

    /// 面板几何变化的统一入口：先按当前屏幕刷新可视高度上限，再对齐窗口。
    private func refreshPanelGeometry() {
        updateVisibleHeightLimit()
        applyCurrentFrame()
    }

    /// 限高只影响显示：窗口比期望高度矮、内容在内部滚动，
    /// 但 `navigation.panelSize` 与用户保存的高度都不动。
    private func updateVisibleHeightLimit() {
        guard let screen = anchorScreen else { return }
        navigation.setMaximumVisibleHeight(
            Double(PanelFramePositioner.maximumVisibleHeight(in: screen.visibleFrame))
        )
    }

    @objc private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    /// 左击开关面板；右击只弹菜单（先把面板收起）。
    /// 二次点击有多种来源：真右键（rightMouseDown）、control-左击，以及
    /// 第三方鼠标工具合成的事件；只要不是普通左击都按二次点击处理。
    @objc private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true
        guard isSecondary else {
            togglePanel()
            return
        }
        presentContextMenu()
    }

    /// 弹出右击菜单。statusItem.menu 非空说明正处在菜单弹出期间，忽略重入。
    private func presentContextMenu() {
        guard let statusItem else { return }
        guard statusItem.menu == nil else { return }
        hidePanel()
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// 面板不再保留底部操作行：添加订阅、设置、退出都走右击菜单。
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        // 图标用面板里「添加订阅」同一个 plus 符号；设置项的齿轮由系统自动加。
        let addItem = menuItem(title: "添加订阅", action: #selector(addSubscription))
        addItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(addItem)
        menu.addItem(menuItem(title: "设置…", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "退出 TokenMeter", action: #selector(quit)))
        return menu
    }()

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func addSubscription() {
        navigation.beginAdding()
        showPanel()
    }

    @objc private func openSettings() {
        navigation.route = .settings
        showPanel()
    }

    @objc private func quit() {
        store.stop()
        NSApplication.shared.terminate(nil)
    }

    private func showPanel() {
        guard isStarted else { return }
        // 窗口尺寸只用当前路由记住的高度（navigation 在切页时就已同步好）：
        // 借用别的页面的尺寸会让内容被居中裁掉上下两端。
        updateVisibleHeightLimit()
        guard let frame = frame(for: navigation.displayedSize) else { return }

        // 先设置最终 frame，再显示窗口；自有面板不会经过系统的二次重摆。
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()

        if visibilityGate.didReceiveDisplayEvent(), store.settings.refreshOnOpen {
            store.refreshAll(source: .panelOpen)
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

    /// 面板锚定的屏幕：状态栏按钮所在屏幕 → 按钮中心命中的屏幕 → 主屏。
    private var anchorScreen: NSScreen? {
        guard let buttonWindow = statusItem?.button?.window else { return NSScreen.main }
        if let screen = buttonWindow.screen { return screen }
        guard let buttonFrame = statusButtonFrame else { return NSScreen.main }
        let buttonCenter = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(buttonCenter) } ?? NSScreen.main
    }

    private func frame(for size: PanelSize) -> NSRect? {
        guard let screen = anchorScreen else { return nil }
        let contentSize = NSSize(width: size.width, height: size.height)
        guard let buttonFrame = statusButtonFrame else {
            return PanelFramePositioner.frame(
                contentSize: contentSize,
                screenFrame: screen.visibleFrame,
                anchorX: screen.visibleFrame.midX,
                anchorTop: screen.visibleFrame.maxY
            )
        }
        return PanelFramePositioner.frame(
            contentSize: contentSize,
            screenFrame: screen.visibleFrame,
            anchorX: buttonFrame.midX,
            anchorTop: buttonFrame.minY
        )
    }

    private func applyCurrentFrame() {
        // 不按可见性跳过：从右击菜单触发的导航发生在菜单跟踪循环里，
        // orderFrontRegardless 会被推迟到菜单关闭后才生效，此时内容已经报出新高度。
        // 若此时丢弃，窗口就会停在旧高度，内容上下被裁。
        guard let frame = frame(for: navigation.displayedSize) else { return }
        guard abs(panel.frame.minX - frame.minX) > 0.5
            || abs(panel.frame.minY - frame.minY) > 0.5
            || abs(panel.frame.width - frame.width) > 0.5
            || abs(panel.frame.height - frame.height) > 0.5 else { return }
        panel.setFrame(frame, display: true)
    }
}
