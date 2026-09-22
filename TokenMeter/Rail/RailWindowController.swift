import AppKit
import SwiftUI

/// 悬浮条的窗口控制器：窗口生命周期、放置、层级与跨屏跟随。
///
/// 移植自 Pulse 的 `FloatingPanelController`，去掉它的账号拆分与活动扫描。
///
/// 与 `MenuBarPanelController`（管理面板）完全独立：那是点状态栏图标弹出、
/// 点外面就收起的面板，这是常驻在屏幕边上的条。两者互不干涉。
@MainActor
final class RailWindowController {
    private let store: UsageStore
    private let settings: SettingsStore
    private let placement: RailPlacement
    private let panel: RailWindow
    private var hostingView: NSHostingView<RailView>?
    /// 只在 `init` 里写一次、只在 `deinit` 里读一次；`deinit` 是 nonisolated 的，
    /// 够不到 main-actor 属性，所以标成 `nonisolated(unsafe)`。别的任何地方都不碰它。
    nonisolated(unsafe) private var screenObserver: (any NSObjectProtocol)?
    /// 盯着指针在哪块屏上，开着那个设置时才跑。
    private let displayFollower = RailDisplayFollower()
    private var isStarted = false

    init(store: UsageStore, settings: SettingsStore, placement: RailPlacement) {
        self.store = store
        self.settings = settings
        self.placement = placement

        let initialSize = Self.panelSize(
            for: placement.edge,
            entryCount: RailEntryBuilder.railSubscriptions(from: store.subscriptions).count,
            docked: placement.isDocked,
            notch: nil
        )
        panel = RailWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        installContent(initialSize: initialSize)
        installCallbacks()

        // 在设置或菜单里换位置只改放置，不移动窗口；没有这一句内容会镜像过来而窗口留在原地，
        // 条就搁浅在屏幕中间了。
        placement.onChange = { [weak self] in
            self?.placePanel()
        }

        // 显示器会来会走：拔掉一块屏、合上盖子接上扩展坞、在系统设置里重排。
        // 任何一件都会把条留在一个不再存在的空间里，而且没有路让它回来，
        // 所以屏幕一变就重新放置。拖动中除外——那已经在移动窗口本身了，
        // 重新放置会和它抢同一个 frame。
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placement.isDragging else { return }
                // 指针没动，但它底下的显示器可能已经不是刚才那块了——
                // 条也可能刚掉到一块谁也没选的屏上。重新问一次。
                self.displayFollower.forgetLastDisplay()
                self.placePanel()
            }
        }

        // 把条带到指针所在的那块屏上，就是这个功能的全部：只有一条条，它移动过去。
        // 条被握着时拒绝是 `move(toDisplay:)` 自己的规则，把那次拒绝原样返回，
        // 这块显示器就还有下一次机会，而不是被记成已经处理过。
        displayFollower.onEnter = { [placement] identifier in
            placement.move(toDisplay: identifier)
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// 条上右键弹出的菜单。
    ///
    /// 从外面传进来而不是在这里造：上面该有什么是设置、面板和退出，
    /// 这个类对它们一无所知。每次点击现做，这样自上次以来出现的新东西能在菜单上。
    var contextMenu: (() -> NSMenu)? {
        get { panel.contextMenu }
        set { panel.contextMenu = newValue }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if wantsVisible { show() }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        displayFollower.stop()
        panel.orderOut(nil)
    }

    func show() {
        // **放置、显示、再放置**，第二次才算数。
        //
        // `placePanel` 量的是条在窗口里相对于窗口**实际拿到**的 frame 的位置，
        // 而不是它请求的那个——条带着全部订阅时窗口比笔记本的可用区还高，AppKit 会把它拉下来。
        // 但一个从未 order in 过的窗口还不受这个约束：`setFrame` 存的是请求值，
        // `frame` 读回来原样不变，量到的偏移是相对一个窗口即将失去的位置。
        // 把它显示出来才会施加约束，那时条已经画偏了。
        //
        // 第一次调用不是白费的：它让窗口在显示之前先大致到位，
        // 不会从原点出现再滑过去。
        placePanel()
        panel.orderFrontRegardless()
        placePanel()
        applyDisplayFollowing()
    }

    func toggle() {
        panel.isVisible ? panel.orderOut(nil) : show()
        applyDisplayFollowing()
    }

    /// 让窗口跟上刚改过的设置。
    func settingsChanged() {
        applyCollectionBehavior()
        applyDisplayFollowing()

        if wantsVisible {
            if !panel.isVisible { show() }
            // 关掉一个供应商会缩短条，而条在窗口里坐哪儿是按它的长度算出来的——
            // 这里必须重做，否则条会从它被放下的地方漂走。
            placePanel()
        } else {
            displayFollower.stop()
            panel.orderOut(nil)
        }
    }

    /// 订阅增删、或者某条订阅的「在悬浮条中显示」被改过之后，条的尺寸变了，窗口要跟上。
    ///
    /// 一个环都没有时把条收掉：一条空白胶囊什么也读不出来，还占着屏幕边。
    func railLengthChanged() {
        guard isStarted, settings.railEnabled else { return }
        guard hasEntries else {
            displayFollower.stop()
            panel.orderOut(nil)
            return
        }
        if panel.isVisible { placePanel() } else { show() }
    }

    /// 条该不该在屏幕上。
    ///
    /// 开关开着、而且条上真的有东西可看。全部订阅都被关掉「在悬浮条中显示」时，
    /// 一条空条比没有条更让人费解。
    private var wantsVisible: Bool { settings.railEnabled && hasEntries }

    private var hasEntries: Bool { !railSubscriptions.isEmpty }

    /// 条上真正画出来的订阅。顺序即数组顺序，环的索引直接对应它。
    private var railSubscriptions: [Subscription] {
        RailEntryBuilder.railSubscriptions(from: store.subscriptions)
    }

    /// 从右键菜单换位置。只改放置，重新摆放由 `placement.onChange` 收口。
    func move(to dock: RailDock) {
        placement.update(dock: dock)
    }

    private func configurePanel() {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.applyLevel(for: placement.dock)
        applyCollectionBehavior()
    }

    /// 让条在每一个普通桌面空间上都可见，同时单独决定它能不能跟着别的 app
    /// 进到全屏空间里。
    ///
    /// `.fullScreenAuxiliary` 是显式选择「进全屏」时用的公开选项，
    /// `.fullScreenNone` 是配套的显式退出——不需要任何 app 探测、空间轮询或辅助功能权限。
    private func applyCollectionBehavior() {
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            settings.railHidesInFullScreen ? .fullScreenNone : .fullScreenAuxiliary,
            .stationary,
        ]
    }

    /// 开始或停止盯指针在哪块屏上。
    ///
    /// 条不在屏幕上、或这个设置关着时什么都不采样，所以只有一块屏的人、
    /// 或者把这项关掉的人，不会为任何定时器付钱。
    private func applyDisplayFollowing() {
        guard settings.railEnabled, settings.railFollowsActiveDisplay, panel.isVisible else {
            displayFollower.stop()
            return
        }
        // 存着的那块屏可能是指针很久以前离开的那块，所以第一次 tick 必须能报出它真正在哪。
        displayFollower.forgetLastDisplay()
        displayFollower.start()
    }

    private func installContent(initialSize: CGSize) {
        let hostingView = NSHostingView(
            rootView: RailView(
                store: store,
                settings: settings,
                placement: placement,
                onRailLengthChange: { [weak self] in self?.railLengthChanged() }
            )
        )
        // 宿主只负责填满窗口：窗口尺寸由这里的几何算出来，不是由内容拟合出来的。
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.hostingView = hostingView
    }

    private func installCallbacks() {
        panel.placement = placement

        // 什么可以被抓住。卷起来时屏幕上没有条可以抓，只有细条——
        // 在条**本该**占据的那六十点空处按一下必须落到它背后的东西上，而不是移动它。
        panel.grabArea = { [weak self] in
            guard let self else { return .zero }
            if self.placement.notch != nil && !self.placement.isRailExpanded { return .zero }
            let railSize = self.currentRailSize
            let rail = RailHitArea.rail(
                edge: self.placement.edge,
                railSize: railSize,
                panelSize: self.currentPanelSize,
                railTop: self.placement.railTop,
                railLeading: self.placement.railLeading
            )
            if self.placement.isRailExpanded {
                return self.placement.notch.map {
                    RailHitArea.notchSurface(rail: rail, notchSize: $0.size)
                } ?? rail
            }
            return RailHitArea.strip(
                edge: self.placement.edge,
                railSize: railSize,
                panelSize: self.currentPanelSize,
                railTop: self.placement.railTop,
                railLeading: self.placement.railLeading
            )
        }

        // 条自己的矩形，不论当前在屏幕上是什么状态。卷起来时抓到的是细条，
        // 但被**放置**的仍然是条。
        panel.railFrame = { [weak self] in
            guard let self else { return .zero }
            return RailHitArea.rail(
                edge: self.placement.edge,
                railSize: self.currentRailSize,
                panelSize: self.currentPanelSize,
                railTop: self.placement.railTop,
                railLeading: self.placement.railLeading
            )
        }

        // 条还没到的那条边上，条会是多大——拖动需要它。
        // 收的是它**即将**落上去的那条边，不是正在离开的那条：离开边的那一刻两端就
        // 少掉了外扩的那段留白，按旧状态量会在改轴的那一帧把放置算错那么多。
        panel.railSize = { [weak self] edge, docked in
            guard let self else { return .zero }
            return Self.railSize(for: edge, entryCount: self.railSubscriptions.count, docked: docked)
        }

        // 一次短按（没有移动过）落在某个环上就刷新那条订阅。条身上的空白仍然只用于拖动。
        panel.onClick = { [weak self] point in
            guard let self, self.placement.isRailExpanded else { return }
            let entries = self.entries
            let railSize = self.currentRailSize
            guard let index = RailHitArea.slot(
                at: point,
                edge: self.placement.edge,
                entryCount: entries.count,
                railSize: railSize,
                panelSize: self.currentPanelSize,
                railTop: self.placement.railTop,
                railLeading: self.placement.railLeading,
                docked: self.placement.isDocked
            ) else { return }
            guard index < entries.count else { return }
            // 环的顺序就是条上订阅的顺序，所以索引直接对应。
            let subscription = self.railSubscriptions[index]
            self.store.refresh(subscription)
        }
    }

    // MARK: - 几何

    private var entries: [RailEntry] {
        RailEntryBuilder.entries(subscriptions: store.subscriptions, snapshots: store.snapshots)
    }

    private var currentRailSize: CGSize {
        Self.railSize(
            for: placement.edge,
            entryCount: railSubscriptions.count,
            docked: placement.isDocked
        )
    }

    private var currentPanelSize: CGSize {
        RailHitArea.panelSize(
            for: placement.edge,
            railLength: max(currentRailSize.width, currentRailSize.height),
            notchSize: placement.notch?.size
        )
    }

    private static func railSize(for edge: RailEdge, entryCount: Int, docked: Bool) -> CGSize {
        RailLayout.size(for: entryCount, on: edge.axis, docked: docked)
    }

    private static func panelSize(
        for edge: RailEdge,
        entryCount: Int,
        docked: Bool,
        notch: CGRect?
    ) -> CGSize {
        let rail = railSize(for: edge, entryCount: entryCount, docked: docked)
        return RailHitArea.panelSize(for: edge, railLength: max(rail.width, rail.height), notchSize: notch?.size)
    }

    /// 把条停在它上次被留下的地方。
    ///
    /// 条的长度传进来是因为它会在放置过程中变——关掉一个供应商会缩短它，
    /// 而放置是按**条**而不是按窗口说话的，窗口大部分是卡片展开的空间，
    /// 那部分用户从来没有摆放过。
    private func placePanel() {
        guard isStarted else { return }
        // 它被留下的那块屏，如果那块屏还在。拔掉的显示器会回落到一块存在的屏上，
        // 而不是把条停在一个谁也看不见的空间里。
        guard let screen = RailScreen.screen(withIdentifier: placement.display)
            ?? panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        let edge = placement.edge
        placement.notch = edge == .top ? RailScreen.notch(of: screen) : nil

        let railSize = Self.railSize(
            for: edge,
            entryCount: railSubscriptions.count,
            docked: placement.isDocked
        )
        let panelSize = RailHitArea.panelSize(
            for: edge,
            railLength: max(railSize.width, railSize.height),
            notchSize: placement.notch?.size
        )
        let layout = RailGeometry.layout(
            dock: placement.dock,
            horizontalRatio: placement.horizontalRatio,
            verticalRatio: placement.verticalRatio,
            notch: placement.notch,
            visible: screen.visibleFrame,
            topEdge: RailGeometry.topEdge(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                topInset: screen.safeAreaInsets.top
            ),
            panel: panelSize,
            rail: railSize
        )

        panel.applyLevel(for: placement.dock)
        panel.setFrame(layout.frame, display: true)
        // **按窗口实际拿到的 frame 量**，不是请求的那个。条带着全部订阅时窗口比笔记本的
        // 可用区还高，AppKit 不会给一个放不下的 frame——两半放置就会差出它拒绝的那些，
        // 条也会画偏那么多。
        let offsets = RailGeometry.offsets(forRailTopLeft: layout.railOrigin, in: panel.frame, rail: railSize)
        placement.setRailOffset(top: offsets.top, leading: offsets.leading)
    }
}
