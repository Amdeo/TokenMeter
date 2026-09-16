import AppKit
import SwiftUI
import Testing
@testable import TokenMeter

@MainActor
struct PanelSurfaceTests {
    @Test
    func equalHeightRoutesStillRequestGeometrySynchronization() {
        let routes: [PanelNavigationState.Route] = [
            .overview, .settings, .migration, .addProvider, .addConfiguration,
            .appearance, .editConfiguration(UUID()), .settings, .overview,
        ]
        for (previous, next) in zip(routes, routes.dropFirst()) {
            #expect(
                PanelGeometryRequest(route: previous, size: .compact)
                    != PanelGeometryRequest(route: next, size: .compact)
            )
        }
        #expect(
            PanelGeometryRequest(route: .overview, size: .compact)
                != PanelGeometryRequest(route: .overview, size: PanelSize(width: 340, height: 724))
        )
    }

    /// 不同页面的高度只改变窗口底边，等高页面也校正宿主；顶部始终贴住菜单栏锚点。
    @Test
    func changingPageHeightsKeepsTheMenuBarAnchor() {
        let screen = NSRect(x: -1440, y: -120, width: 1440, height: 900)
        let anchorTop = screen.maxY
        let container = PanelContainerView(frame: NSRect(x: 0, y: 0, width: 340, height: 724))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        let hosting = NSHostingView(rootView: Color.clear)
        container.installHostedContentView(hosting)
        for height: CGFloat in [724, 838, 320, 584, 724] {
            let frame = PanelFramePositioner.frame(
                contentSize: NSSize(width: 340, height: height),
                screenFrame: screen,
                anchorX: screen.maxX - 60,
                anchorTop: anchorTop
            )
            container.synchronizeWindowFrame(frame)
            #expect(window.frame.maxY == anchorTop)
            #expect(abs(window.frame.height - height) < 0.01)
            #expect(hosting.frame == container.bounds)

            // 同一窗口尺寸下的重入遗留错位也必须修复，不能因 frame 相同提前返回。
            hosting.frame.size.height -= 28
            container.synchronizeWindowFrame(frame)
            #expect(hosting.frame == container.bounds)
            #expect(window.frame.maxY == anchorTop)
        }
    }
}
