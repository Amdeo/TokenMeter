import SwiftUI
import AppKit
import os

struct PanelVisibilityGate {
    private(set) var isVisible = false

    mutating func didReceiveDisplayEvent() -> Bool {
        guard !isVisible else { return false }
        isVisible = true
        return true
    }

    mutating func didReceiveHiddenEvent() { isVisible = false }
}

enum PanelLayoutMetrics {
    /// 面板窗口圆角；由 contentView（`PanelContainerView`）的图层遮罩实现。
    static let cornerRadius: CGFloat = 14
    static let rootVerticalChrome: CGFloat = 16
    static let pageChrome: CGFloat = 116
    static let providerChrome: CGFloat = 66
    static let settingsChrome: CGFloat = 108

    /// 概览订阅列表的最大可视高度：内容超过后列表内部滚动，
    /// 面板高度仍随内容自适应，但整体不超过默认面板高度量级。
    static let subscriptionListMaxHeight: CGFloat = 480
}

struct IntrinsicPanelHeightModifier: ViewModifier {
    let route: PanelNavigationState.Route
    let chrome: CGFloat

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PanelHeightPreferenceKey.self,
                    value: PanelHeightMeasurement(route: route, height: geometry.size.height + chrome)
                )
            }
        }
    }
}

extension View {
    func reportsIntrinsicPanelHeight(route: PanelNavigationState.Route, chrome: CGFloat) -> some View {
        modifier(IntrinsicPanelHeightModifier(route: route, chrome: chrome))
    }
}

enum PanelFramePositioner {
    static let screenMargin: CGFloat = 8

    /// 面板在给定屏幕可视范围内允许的最大高度：上下各留一个边距。
    /// 高度超过它时锚点钳制会让面板顶边越过屏幕上沿，头部返回按钮跟着跑到屏幕外。
    static func maximumVisibleHeight(in screenFrame: NSRect) -> CGFloat {
        max(screenFrame.height - screenMargin * 2, 0)
    }

    static func frame(
        contentSize: NSSize,
        screenFrame: NSRect,
        anchorX: CGFloat,
        anchorTop: CGFloat
    ) -> NSRect {
        let width = max(contentSize.width, 0)
        let height = max(contentSize.height, 0)
        let minimumX = screenFrame.minX + screenMargin
        let maximumX = screenFrame.maxX - screenMargin - width
        let centeredX = anchorX - width / 2
        let horizontalOrigin = maximumX >= minimumX
            ? min(max(centeredX, minimumX), maximumX)
            : screenFrame.midX - width / 2

        // 状态栏锚点位于屏幕可视区域上沿附近；只在面板过高时向上钳制，
        // 正常情况下保持面板顶边与状态栏按钮下沿完全重合。
        let minimumY = screenFrame.minY + screenMargin
        let maximumY = screenFrame.maxY - height
        let desiredY = anchorTop - height
        let verticalOrigin = maximumY >= minimumY
            ? min(max(desiredY, minimumY), maximumY)
            : screenFrame.minY
        return NSRect(x: horizontalOrigin, y: verticalOrigin, width: width, height: height)
    }
}

/// 面板容器：窗口内容视图。圆角遮罩在每次布局时重申 ——
/// AppKit 创建后备图层后会丢掉 `makeBackingLayer()` 里设的形状，图层重建（wantsLayer 关→开）
/// 也会把一次性赋值的圆角清回 0；`layout()` 在 AppKit 建立/更新图层之后运行，
/// 所以形状能跟上图层重建与尺寸变化。
///
/// 宿主内容（SwiftUI 视图）由控制器注册进来，尺寸必须恒等于容器 bounds：
/// 宿主一旦比容器矮，内容就会整块贴到底部、顶部露出空白，而窗口在手动高度下不会再变化，
/// 错位会一直保留。`layout()` 只观测不纠正 —— 几何由约束保证，这里记录一次便于复发时定位。
@MainActor
final class PanelContainerView: NSView {
    private static let logger = Logger(subsystem: "com.tokenmeter.app", category: "panel")

    /// 面板内容宿主视图；由 `MenuBarPanelController` 在装配时注册。
    weak var hostedContentView: NSView?

    override func layout() {
        super.layout()
        if let hostedContentView, hostedContentView.frame != bounds {
            let hostFrame = NSStringFromRect(hostedContentView.frame)
            let containerBounds = NSStringFromRect(self.bounds)
            let windowFrame = NSStringFromRect(self.window?.frame ?? .zero)
            let safeArea = String(describing: hostedContentView.safeAreaInsets)
            Self.logger.error("""
            panel host geometry drift host=\(hostFrame, privacy: .public) \
            bounds=\(containerBounds, privacy: .public) \
            window=\(windowFrame, privacy: .public) \
            safe=\(safeArea, privacy: .public)
            """)
        }
        guard let layer else { return }
        layer.cornerRadius = PanelLayoutMetrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }
}

struct PanelHeightResizeHandle: NSViewRepresentable {
    let panelHeight: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> PanelHeightResizeNSView {
        let view = PanelHeightResizeNSView()
        view.panelHeight = panelHeight
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: PanelHeightResizeNSView, context: Context) {
        nsView.panelHeight = panelHeight
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}

@MainActor
final class PanelHeightResizeNSView: NSView {
    var panelHeight = CGFloat(PanelSize.compact.height)
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?
    private var startMouseY: CGFloat?
    private var startHeight = CGFloat(PanelSize.compact.height)
    private var latestHeight = CGFloat(PanelSize.compact.height)
    private var didDrag = false
    private var trackingArea: NSTrackingArea?
    private var isResizing = false
    private var resizeCursorIsActive = false

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseEntered(with event: NSEvent) {
        setResizeCursor()
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing {
            restoreCursor()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            restoreCursor()
        }
        super.viewWillMove(toWindow: newWindow)
        newWindow?.invalidateCursorRects(for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        isResizing = true
        setResizeCursor()
        startMouseY = NSEvent.mouseLocation.y
        startHeight = panelHeight
        latestHeight = panelHeight
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouseY else { return }
        let height = startHeight + startMouseY - NSEvent.mouseLocation.y
        guard didDrag || abs(height - startHeight) >= 1 else { return }
        didDrag = true
        latestHeight = height
        onChanged?(height)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startMouseY = nil
            didDrag = false
            isResizing = false
            restoreCursor()
        }
        guard didDrag else { return }
        onEnded?(latestHeight)
    }

    private func setResizeCursor() {
        guard !resizeCursorIsActive else { return }
        NSCursor.resizeUpDown.push()
        resizeCursorIsActive = true
    }

    private func restoreCursor() {
        guard resizeCursorIsActive else { return }
        NSCursor.pop()
        resizeCursorIsActive = false
    }
}

/// 原生系统玻璃背景：NSVisualEffectView 磨砂材质，透出并模糊窗口背后的内容。
/// 浅色主题在 macOS 14–25 使用（质感同系统菜单下拉）；深色主题仍用自定义渐变。
struct NativeGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// macOS 26+ 的 Liquid Glass 面板背景：以覆盖整个面板的透明形状作为唯一的外层玻璃表面，
/// 随面板背后的桌面/窗口内容实时折射与模糊。
/// 玻璃形状自带与面板容器一致的圆角：系统玻璃可能绕过视图图层的遮罩，
/// 让四个角在面板上直接变直角。
/// 外层只保留这一层玻璃，卡片用低透明度填充而非再叠 glassEffect（避免玻璃叠玻璃）。
@available(macOS 26.0, *)
struct LiquidGlassBackground: View {
    var body: some View {
        Color.clear
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: PanelLayoutMetrics.cornerRadius, style: .continuous)
            )
    }
}

/// 让面板窗口透明并按设置强制窗口外观：
/// 动态 NSColor 令牌与 .regularMaterial 都按窗口 effective appearance 解析，
/// 因此需要直接设置 window.appearance。
struct PanelWindowAppearanceBridge: NSViewRepresentable {
    let appearanceMode: AppearanceMode

    func makeNSView(context: Context) -> PanelAppearanceNSView {
        let view = PanelAppearanceNSView()
        view.appearanceMode = appearanceMode
        return view
    }

    func updateNSView(_ nsView: PanelAppearanceNSView, context: Context) {
        nsView.appearanceMode = appearanceMode
        nsView.applyIfNeeded()
    }
}

final class PanelAppearanceNSView: NSView {
    var appearanceMode: AppearanceMode = .system

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    func applyIfNeeded() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        // SwiftUI 宿主 view（NSHostingView 等）默认可能带不透明 layer 背景，
        // 会挡在玻璃材质后方使浅色面板呈实心白；显式清空 contentView 的 layer 背景，
        // 让玻璃（Liquid Glass / NSVisualEffectView）真正处于窗口合成底层。
        // wantsLayer 重复设置与重复赋透明背景均幂等。
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        let target: NSAppearance? = switch appearanceMode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        // 幂等：只在目标外观变化时更新，避免外观切换递归触发 layout/resize。
        if window.appearance != target { window.appearance = target }
    }
}
