import AppKit
import Foundation
import Testing
import SwiftUI
@testable import TokenMeter

/// 菜单面板布局稳定性回归：路由切换时的尺寸同步、屏幕限高、真实根视图布局与容器圆角生命周期。
@MainActor
struct PanelLayoutStabilityTests {

    // MARK: - 路由尺寸同步

    /// 切页必须立刻用目标页记住的高度（手动高度优先，其次是它上次的测量值）。
    /// 窗口尺寸与 SwiftUI 根视图必须同时切换：只改其中一个时，原生窗口会停在旧高度，
    /// 内容被居中裁掉首尾，顶部的返回按钮既看不到也点不到。
    @Test
    func routeSwitchAdoptsRememberedHeightBeforeThePageReportsBack() {
        let navigation = freshNavigationState()
        navigation.route = .settings
        navigation.reportMeasuredHeight(700, for: .settings)
        navigation.route = .addProvider
        navigation.reportMeasuredHeight(500, for: .addProvider)

        navigation.route = .settings
        #expect(navigation.panelSize.height == 700)

        navigation.route = .addProvider
        #expect(navigation.panelSize.height == 500)

        // 没量过的页面沿用当前高度，等它自己报出测量值再校准。
        navigation.route = .migration
        #expect(navigation.panelSize.height == 500)
    }

    /// 手动高度优先于该页的历史测量值，往返也不丢。
    @Test
    func routeSwitchAdoptsManualHeightAheadOfMeasurement() {
        let navigation = freshNavigationState()
        navigation.route = .settings
        navigation.setUserHeight(640, persist: false)
        navigation.route = .overview
        navigation.reportMeasuredHeight(500, for: .overview)
        navigation.route = .settings
        #expect(navigation.panelSize.height == 640)
    }

    // MARK: - 屏幕边界

    /// 显示高度按屏幕可视区收缩后，面板在任意屏幕（含负原点、非主屏）上都留在可视区内；
    /// 顶边贴着锚点、底边不压屏幕下沿，头部返回按钮始终点得到。
    @Test
    func fittedPanelAlwaysStaysInsideTheVisibleFrame() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1728, height: 1117),
            NSRect(x: 0, y: 0, width: 1200, height: 700),
            NSRect(x: -1280, y: -200, width: 1280, height: 800),
            NSRect(x: 0, y: 0, width: 800, height: 500),
        ]
        for screen in screens {
            let limit = PanelFramePositioner.maximumVisibleHeight(in: screen)
            #expect(limit == screen.height - PanelFramePositioner.screenMargin * 2)
            for requestedHeight in [320.0, 584.0, 900.0] as [CGFloat] {
                let size = NSSize(width: PanelSize.compact.width, height: min(requestedHeight, limit))
                let frame = PanelFramePositioner.frame(
                    contentSize: size,
                    screenFrame: screen,
                    anchorX: screen.midX,
                    anchorTop: screen.maxY - 10
                )
                #expect(frame.height == size.height)
                #expect(frame.maxY <= screen.maxY - PanelFramePositioner.screenMargin + 0.001)
                #expect(frame.minY >= screen.minY + PanelFramePositioner.screenMargin - 0.001)
                #expect(frame.maxX <= screen.maxX - PanelFramePositioner.screenMargin + 0.001)
                #expect(frame.minX >= screen.minX + PanelFramePositioner.screenMargin - 0.001)
            }
        }
    }

    /// 限高只改显示高度：用户保存的手动高度不动，屏幕恢复后回到用户的高度。
    @Test
    func screenLimitCapsDisplayedHeightOnly() {
        let suite = "TokenMeterTests.PanelLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let navigation = PanelNavigationState(defaults: defaults)
        navigation.setUserHeight(880, persist: true)
        navigation.setMaximumVisibleHeight(684)
        #expect(navigation.displayedSize.height == 684)
        #expect(navigation.panelSize.height == 880)
        #expect(navigation.hasManualHeight)
        #expect(navigation.isHeightLimitedByScreen)

        navigation.setMaximumVisibleHeight(nil)
        #expect(navigation.displayedSize.height == 880)
        #expect(!navigation.isHeightLimitedByScreen)
        #expect(PanelNavigationState(defaults: defaults).panelSize.height == 880)
    }

    /// 屏幕比内容高时限高不生效，也不会把面板拉高。
    @Test
    func screenLimitNeverStretchesAShortPanel() {
        let navigation = freshNavigationState()
        navigation.reportMeasuredHeight(400, for: .overview)
        navigation.setMaximumVisibleHeight(684)
        #expect(navigation.displayedSize.height == 400)
        #expect(!navigation.isHeightLimitedByScreen)
    }

    /// 被限高时量到的高度会被窗口压缩（正好等于窗口高度），
    /// 采纳它会让屏幕恢复后高度回不去，所以必须忽略这一轮测量。
    @Test
    func clampedMeasurementDoesNotPoisonTheDesiredHeight() {
        let navigation = freshNavigationState()
        navigation.reportMeasuredHeight(880, for: .overview)
        navigation.setMaximumVisibleHeight(684)
        #expect(navigation.displayedSize.height == 684)

        navigation.reportMeasuredHeight(684, for: .overview)
        #expect(navigation.panelSize.height == 880)

        navigation.setMaximumVisibleHeight(nil)
        #expect(navigation.displayedSize.height == 880)

        // 限高解除后测量重新生效
        navigation.reportMeasuredHeight(520, for: .overview)
        #expect(navigation.panelSize.height == 520)
    }

    // MARK: - 真实根视图布局（隔离 Store）

    /// 用真实 MenuBarView 根视图 + 真实测量链路跑一遍矮屏流程：
    /// 窗口被限高、内容被压缩时，期望高度不能被压缩出来的测量改成窗口高度，
    /// 否则屏幕恢复后高度回不来。
    @Test
    func realRootLayoutKeepsDesiredHeightWhenTheWindowIsShort() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterPanelRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadataURL = directory.appendingPathComponent("subscriptions.json")
        let subscriptions = (0..<6).map { index in
            Subscription(providerID: .kimi, name: "Subscription \(index)", authMethodID: .apiKey)
        }
        try JSONEncoder().encode(subscriptions).write(to: metadataURL)

        let defaultSuite = "TokenMeterTests.PanelRoot.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultSuite))
        defer { defaults.removePersistentDomain(forName: defaultSuite) }
        let store = UsageStore(
            settings: SettingsStore(defaults: defaults),
            metadataURL: metadataURL,
            credentialStore: CredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        )
        #expect(store.subscriptions.count == subscriptions.count)

        let navigation = freshNavigationState()
        let harness = makePanelHost(root: MenuBarView().environment(store).environment(navigation))
        let window = harness.window
        let container = harness.container

        // 模拟控制器的联动：每轮布局后把窗口对齐到 displayedSize，再让 SwiftUI 按新尺寸重排。
        func layoutPasses(_ count: Int) {
            for _ in 0..<count {
                container.layoutSubtreeIfNeeded()
                let displayed = navigation.displayedSize
                window.setContentSize(NSSize(width: displayed.width, height: displayed.height))
                container.layoutSubtreeIfNeeded()
            }
        }

        layoutPasses(4)
        let contentDrivenHeight = navigation.panelSize.height
        #expect(contentDrivenHeight < PanelSize.compact.height)
        #expect(contentDrivenHeight >= PanelSize.minimumAdaptiveHeight)
        // 真实根视图不跟容器抢尺寸：宿主同高，窗口尺寸就是内容布局的提案。
        #expect(harness.hosting.frame.height == container.bounds.height)
        #expect(harness.hosting.frame.width == container.bounds.width)

        // 矮屏：窗口被限高，内容比窗口高。
        navigation.setMaximumVisibleHeight(320)
        layoutPasses(4)
        #expect(navigation.displayedSize.height == 320)
        #expect(navigation.panelSize.height == contentDrivenHeight)

        // 屏幕恢复：期望高度必须回到内容高度，而不是停在限高值。
        navigation.setMaximumVisibleHeight(nil)
        layoutPasses(4)
        #expect(navigation.panelSize.height == contentDrivenHeight)
        #expect(navigation.displayedSize.height > 320)
        #expect(harness.hosting.frame.height == container.bounds.height)
    }

    // MARK: - 图层生命周期

    /// 容器在布局时应用圆角遮罩：内容显示前遮罩已就位。
    @Test
    func containerAppliesRoundedMaskDuringLayout() throws {
        let container = PanelContainerView(frame: NSRect(x: 0, y: 0, width: 340, height: 584))
        container.wantsLayer = true
        container.layoutSubtreeIfNeeded()
        let layer = try #require(container.layer)
        #expect(layer.cornerRadius == PanelLayoutMetrics.cornerRadius)
        #expect(layer.cornerCurve == .continuous)
        #expect(layer.masksToBounds)
    }

    /// 图层重建（wantsLayer 关→开）会清掉一次性赋值的圆角，
    /// 容器必须在下一次布局里把遮罩补回来，面板才不会掉回直角。
    @Test
    func containerKeepsRoundedMaskWhenTheBackingLayerIsRebuilt() throws {
        let container = PanelContainerView(frame: NSRect(x: 0, y: 0, width: 340, height: 584))
        container.wantsLayer = true
        container.layoutSubtreeIfNeeded()
        container.wantsLayer = false
        container.wantsLayer = true
        container.layoutSubtreeIfNeeded()
        let layer = try #require(container.layer)
        #expect(layer.cornerRadius == PanelLayoutMetrics.cornerRadius)
        #expect(layer.masksToBounds)
    }

    /// 面板高度随屏幕/内容变化后圆角仍在：尺寸变化不会把遮罩丢掉。
    @Test
    func containerKeepsRoundedMaskWhenResized() throws {
        let container = PanelContainerView(frame: NSRect(x: 0, y: 0, width: 340, height: 584))
        container.wantsLayer = true
        for height in [320.0, 700.0, 584.0] {
            container.frame = NSRect(x: 0, y: 0, width: 340, height: height)
            container.layoutSubtreeIfNeeded()
            let layer = try #require(container.layer)
            #expect(layer.cornerRadius == PanelLayoutMetrics.cornerRadius)
            #expect(layer.masksToBounds)
        }
    }

    /// 宿主视图靠约束跟随容器：面板窗口变高变矮后宿主必须同尺寸，否则内容会被裁。
    @Test
    func hostingViewTracksContainerSizeThroughWindowResize() {
        let harness = makePanelHost(root: Color.clear)
        let window = harness.window
        let container = harness.container
        let hosting = harness.hosting

        container.layoutSubtreeIfNeeded()
        #expect(hosting.frame.height == container.bounds.height)

        window.setContentSize(NSSize(width: 340, height: 320))
        container.layoutSubtreeIfNeeded()
        #expect(container.bounds.height == 320)
        #expect(hosting.frame.height == container.bounds.height)
        #expect(hosting.frame.width == container.bounds.width)

        window.setContentSize(NSSize(width: 340, height: 700))
        container.layoutSubtreeIfNeeded()
        #expect(hosting.frame.height == container.bounds.height)
    }

    /// 宿主视图与容器几何不一致时必须由约束纠正：宿主被外力改小（平台视图插约束、布局引擎
    /// 重解、被跳过的布局）后，内容会整块贴到底部、顶部露出空白，而手动高度下面板窗口不会再
    /// 变化，错位就永久保留（用户现场：窗口 724pt，内容与玻璃只有 638pt 且贴底）。
    @Test
    func hostedContentViewIsPulledBackToContainerBounds() {
        let harness = makePanelHost(root: Color.clear, height: 724)
        let window = harness.window
        let container = harness.container
        let hosting = harness.hosting

        container.layoutSubtreeIfNeeded()
        #expect(hosting.frame == container.bounds)

        // 模拟失同步：宿主比容器矮 86pt（贴底、顶部留白）。
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: container.bounds.width,
            height: container.bounds.height - 86
        )
        #expect(hosting.frame.height != container.bounds.height)

        container.layoutSubtreeIfNeeded()
        #expect(hosting.frame == container.bounds)
        #expect(hosting.frame.height == window.frame.height)
    }

    /// 组装与生产一致的链路：面板容器 → NSHostingView → 无边框窗口。
    /// 宿主尺寸由四边约束钉死在容器上（与 `MenuBarPanelController.start()` 一致），
    /// 测试里不创建真实状态栏与菜单。
    private func makePanelHost(
        root: some View,
        height: CGFloat = 584
    ) -> (window: NSWindow, container: PanelContainerView, hosting: NSHostingView<AnyView>) {
        let container = PanelContainerView(frame: NSRect(x: 0, y: 0, width: 340, height: height))
        container.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.frame = container.bounds
        container.hostedContentView = hosting
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return (window, container, hosting)
    }

    private func freshNavigationState() -> PanelNavigationState {
        let suite = "TokenMeterTests.PanelLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return PanelNavigationState(defaults: defaults)
    }
}
