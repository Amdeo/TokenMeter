import AppKit
import Foundation
import Testing
import SwiftUI
@testable import TokenMeter

/// 菜单面板布局稳定性回归：路由切换时的尺寸同步、屏幕限高、容器圆角遮罩与宿主尺寸跟随。
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

    /// 面板高过屏幕可视区且不做限高时，顶边会落到屏幕上沿之外：
    /// 返回按钮跑到菜单栏后面，既看不见也点不到。
    @Test
    func oversizePanelWouldLeaveTheVisibleFrameWithoutALimit() {
        let screen = NSRect(x: 0, y: 0, width: 1200, height: 700)
        let frame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 340, height: 900),
            screenFrame: screen,
            anchorX: 600,
            anchorTop: 690
        )
        #expect(frame.maxY > screen.maxY)
    }

    /// 按屏幕上限收缩后，面板顶边不再越过屏幕上沿、底边也不压到屏幕下沿。
    @Test
    func fittedPanelStaysInsideTheVisibleFrame() {
        let screen = NSRect(x: 0, y: 0, width: 1200, height: 700)
        let limit = PanelFramePositioner.maximumVisibleHeight(in: screen)
        #expect(limit == 684)
        let frame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 340, height: limit),
            screenFrame: screen,
            anchorX: 600,
            anchorTop: 690
        )
        #expect(frame.height == limit)
        #expect(frame.maxY <= screen.maxY - PanelFramePositioner.screenMargin)
        #expect(frame.minY >= screen.minY + PanelFramePositioner.screenMargin)
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

    // MARK: - 图层生命周期

    /// 容器在布局时应用圆角遮罩：内容显示前遮罩已就位（生产代码里控制器不再自己写图层）。
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

    /// 图层重建（wantsLayer 关→开）会把一次性赋值的圆角清回 0，
    /// 容器必须在下一次布局里把遮罩补回来。
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

    /// 一次性赋值的圆角挡不住图层重建：这正是容器需要在每次布局里重申遮罩的原因。
    /// （对照：不重建图层时一次性赋值能挺过入窗与 resize，见 logs/layer-lifecycle-probes.txt）
    @Test
    func oneShotCornerRadiusDoesNotSurviveLayerRebuild() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 584))
        view.wantsLayer = true
        view.layer?.cornerRadius = PanelLayoutMetrics.cornerRadius
        view.layer?.masksToBounds = true

        view.wantsLayer = false
        view.wantsLayer = true

        #expect(view.layer?.cornerRadius != PanelLayoutMetrics.cornerRadius)
    }

    /// 宿主视图靠自动尺寸跟随容器：面板窗口变高变矮后宿主必须同尺寸，否则内容会被裁。
    /// 同时确认 AppKit 不会把宿主视图挤成内容固有尺寸（无需额外限制 sizingOptions）。
    @Test
    func hostingViewTracksContainerSizeThroughWindowResize() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 584))
        container.wantsLayer = true
        let hosting = NSHostingView(rootView: AnyView(Color.clear))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 584),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
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

    private func freshNavigationState() -> PanelNavigationState {
        let suite = "TokenMeterTests.PanelLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return PanelNavigationState(defaults: defaults)
    }
}
