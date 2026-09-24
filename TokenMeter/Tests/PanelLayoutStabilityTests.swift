import AppKit
import Foundation
import Testing
import SwiftUI
@testable import TokenMeter

/// 菜单面板布局稳定性回归：高度采纳与屏幕限高、真实根视图布局与容器圆角生命周期。
@MainActor
struct PanelLayoutStabilityTests {

    // MARK: - 高度采纳

    /// 面板只剩概览一页，高度只有两个来源：内容量出来的，和用户拖出来的。
    /// 内容量出来的立刻生效（面板要随订阅增删变高变矮）。
    @Test
    func measuredHeightBecomesThePanelHeight() {
        let navigation = freshNavigationState()
        navigation.reportMeasuredHeight(700)
        #expect(navigation.panelSize.height == 700)
        navigation.reportMeasuredHeight(500)
        #expect(navigation.panelSize.height == 500)
    }

    /// 手动高度优先于测量值：用户拖出来的高度不该被下一次测量改掉。
    @Test
    func manualHeightOutranksMeasurement() {
        let navigation = freshNavigationState()
        navigation.setUserHeight(640, persist: false)
        navigation.reportMeasuredHeight(500)
        #expect(navigation.panelSize.height == 640)
        #expect(navigation.hasManualHeight)
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
        navigation.reportMeasuredHeight(400)
        navigation.setMaximumVisibleHeight(684)
        #expect(navigation.displayedSize.height == 400)
        #expect(!navigation.isHeightLimitedByScreen)
    }

    /// 被限高时量到的高度会被窗口压缩（正好等于窗口高度），
    /// 采纳它会让屏幕恢复后高度回不去，所以必须忽略这一轮测量。
    @Test
    func clampedMeasurementDoesNotPoisonTheDesiredHeight() {
        let navigation = freshNavigationState()
        navigation.reportMeasuredHeight(880)
        navigation.setMaximumVisibleHeight(684)
        #expect(navigation.displayedSize.height == 684)

        navigation.reportMeasuredHeight(684)
        #expect(navigation.panelSize.height == 880)

        navigation.setMaximumVisibleHeight(nil)
        #expect(navigation.displayedSize.height == 880)

        // 限高解除后测量重新生效
        navigation.reportMeasuredHeight(520)
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

    /// 右击菜单导航路径（添加订阅 / 设置…）：窗口 frame 在菜单跟踪循环里被改掉时，SwiftUI 会
    /// 跳过那次布局（`NSHostingView is being laid out reentrantly ... the current layout pass
    /// will be skipped.`），四边约束没有机会求解，宿主就停在陈旧尺寸上；手动高度下窗口不再
    /// 变化、面板也不刷新，之后不会再有布局 pass，错位一直保留（实测：窗口 810pt、宿主 896pt）。
    ///
    /// 这里只走生产入口 —— 测试自己不调 `layoutSubtreeIfNeeded()`，撤销补修后宿主就回不到容器
    /// 尺寸（实测重建的窗口改尺寸会顺带同步求解一次，所以失同步必须在改完尺寸之后制造，
    /// 否则测试会掩盖缺陷）。
    @Test
    func forcedGeometrySolvePullsTheHostBackAfterTheFrameChange() {
        let harness = makePanelHost(root: Color.clear, height: 724)
        let window = harness.window
        let container = harness.container
        let hosting = harness.hosting

        // 路由切到设置页：窗口 frame 改成该页记住的高度。
        window.setContentSize(NSSize(width: 340, height: 810))

        // 被跳过的那次布局留下的错位：宿主比容器高 86pt，顶边跑到窗口上方。
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: container.bounds.width,
            height: container.bounds.height + 86
        )
        #expect(hosting.frame != container.bounds)

        container.resolveHostedGeometry()

        #expect(hosting.frame.height == window.frame.height)
        #expect(hosting.frame == container.bounds)
    }

    /// 增高方向：设置页脚注（登录项/通知状态）异步到达后，测量把面板抬高，容器跟着变高，宿主
    /// 必须同高。NSHostingView 默认按 SwiftUI 内容的 fitting 尺寸给自己加尺寸约束，会一路顶回去：
    /// HEAD 下容器被拽回内容的 fitting 高度（620，而不是请求的 756），窗口停在 810 而宿主留在
    /// 838 的容器里（顶部 28pt 空白，见 drift 日志）。装配里关掉自尺寸后，容器保持请求高度、
    /// 宿主填满它。这里只走生产装配 + 生产求解入口，测试自身不调 `layoutSubtreeIfNeeded()`。
    @Test
    func hostedViewFollowsContainerGrowthEvenWhenTheContentFitsShorter() {
        // 内容自然高度 620，比容器矮 —— 正是自尺寸约束会把宿主钉住的情形。
        let harness = makePanelHost(root: Color.clear.frame(height: 620), height: 728)
        let container = harness.container
        let hosting = harness.hosting

        // 测量把面板抬高 28pt：窗口 frame 的变化最终落到容器 bounds 上。
        container.frame = NSRect(x: 0, y: 0, width: 340, height: 756)
        container.resolveHostedGeometry()

        #expect(container.bounds.height == 756)
        #expect(hosting.frame.height == container.bounds.height)
        #expect(hosting.frame == container.bounds)
    }

    /// 主题切换（App 内浅色/深色）走的是外观传播路径：`window.appearance` 赋值会让 AppKit 同步回调
    /// 内容视图的 `viewDidChangeEffectiveAppearance()`（`.system` 模式下的系统主题变化同样传播到
    /// 内容视图）。这条路径不经过改窗口 frame 的入口，SwiftUI 在其中的重入布局被跳过时，宿主就停在
    /// 旧尺寸上没人拉回：内容整块贴底、顶部与菜单栏之间露出透明间隙。容器必须在外观变化后重新求解。
    @Test
    func appearanceChangePullsTheHostBackToContainerBounds() {
        let harness = makePanelHost(root: Color.clear, height: 838)
        let window = harness.window
        let container = harness.container
        let hosting = harness.hosting

        // 先钉到浅色：系统当前若是深色，下面那次赋值就不是真实的外观变化，AppKit 不会回调。
        window.appearance = NSAppearance(named: .aqua)
        container.layoutSubtreeIfNeeded()
        #expect(hosting.frame == container.bounds)

        // 外观切换期间被跳过的布局留下的错位：宿主停在旧高度（贴底、顶部 28pt 空白）。
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: container.bounds.width,
            height: container.bounds.height - 28
        )
        #expect(hosting.frame != container.bounds)

        window.appearance = NSAppearance(named: .darkAqua)

        #expect(hosting.frame == container.bounds)
    }

    /// 组装与生产一致的链路：面板容器 → NSHostingView → 无边框窗口。
    /// 宿主装配走容器的同一个入口（与 `MenuBarPanelController.start()` 一致），
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
        container.installHostedContentView(hosting)
        return (window, container, hosting)
    }

    private func freshNavigationState() -> PanelNavigationState {
        let suite = "TokenMeterTests.PanelLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return PanelNavigationState(defaults: defaults)
    }
}
