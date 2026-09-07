import SwiftUI
import AppKit

// MARK: - 设计令牌

/// TokenMeter 工具视觉的统一设计令牌，支持明暗双主题；
/// 深色参考 UI/index.html 的克制深色面板语言，浅色配合系统玻璃材质。
enum TM {
    static let panelTop = adaptive(light: NSColor.tokenHex(0xF5F5F4), dark: NSColor.tokenHex(0x222324))
    static let panelMid = adaptive(light: NSColor.tokenHex(0xF5F5F4), dark: NSColor.tokenHex(0x1A1B1C))
    static let panelBottom = adaptive(light: NSColor.tokenHex(0xF5F5F4), dark: NSColor.tokenHex(0x181919))

    // 浅色卡片改用低透明度半透明层：外层玻璃是唯一的不透明感来源，
    // 卡片用轻微内聚层即可被识别，避免大面积白底把玻璃变化压平。
    static let cardFill = adaptive(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.028))
    static let cardFillHover = adaptive(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.07))
    static let fieldFill = adaptive(light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.black.withAlphaComponent(0.19))
    static let border = adaptive(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.07))
    static let borderStrong = adaptive(light: NSColor.black.withAlphaComponent(0.16), dark: NSColor.white.withAlphaComponent(0.14))
    static let divider = adaptive(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.075))
    static let hoverFill = adaptive(light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.065))
    static let meterTrack = adaptive(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.09))

    /// 面板内容区统一水平内边距（root 容器供给，所有页面共享）。
    static let panelHorizontal: CGFloat = 18
    /// 卡片/设置行/表单行内部的统一水平内边距（对齐主页订阅卡片的 11pt）。
    static let cardContentHorizontal: CGFloat = 11

    static let textPrimary = adaptive(light: NSColor.tokenHex(0x1A1B1C), dark: NSColor.tokenHex(0xF4F4F1))
    static let textSecondary = adaptive(light: NSColor.tokenHex(0x5E6461), dark: NSColor.tokenHex(0x8F9391))
    static let textTertiary = adaptive(light: NSColor.tokenHex(0x8B908D), dark: NSColor.tokenHex(0x737875))

    static let accent = adaptive(light: NSColor.tokenHex(0x2B7DE9), dark: NSColor.tokenHex(0x5BAAFF))
    static let ok = adaptive(light: NSColor.tokenHex(0x2E9E6B), dark: NSColor.tokenHex(0x67C89D))
    static let warn = adaptive(light: NSColor.tokenHex(0xB8772A), dark: NSColor.tokenHex(0xD59B5C))
    static let danger = adaptive(light: NSColor.tokenHex(0xC24B3C), dark: NSColor.tokenHex(0xD97B6C))

    /// 深色面板背景渐变；浅色使用系统玻璃材质，见 TMPanelBackground。
    static var panelBackground: LinearGradient {
        LinearGradient(
            colors: [panelTop, panelMid, panelBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private struct TMColorSchemeModifier: ViewModifier {
    let mode: AppearanceMode

    func body(content: Content) -> some View {
        switch mode {
        case .system: content
        case .light: content.environment(\.colorScheme, .light)
        case .dark: content.environment(\.colorScheme, .dark)
        }
    }
}

private extension NSColor {
    static func tokenHex(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// 面板背景：深色用深色渐变，浅色用系统原生玻璃。
/// macOS 26+ 使用 SwiftUI Liquid Glass（glassEffect）作为整个面板唯一的外层玻璃表面；
/// macOS 14–25 回退到经典 AppKit 菜单磨砂（NSVisualEffectView(.menu)）。
struct TMPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            TM.panelBackground
        } else {
            if #available(macOS 26.0, *) {
                LiquidGlassBackground()
            } else {
                NativeGlassBackground()
            }
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// 低透明度描边卡片容器。
struct TMCardModifier: ViewModifier {
    var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? TM.cardFillHover : TM.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? TM.borderStrong : TM.border, lineWidth: 1)
            )
    }
}

extension View {
    func tmCard(hovering: Bool = false) -> some View {
        modifier(TMCardModifier(hovering: hovering))
    }
}

/// 订阅卡片行在排序列表坐标系中的布局 frame（[id: CGRect]），
/// 供 DragGesture 实时换位比较相邻行中线。
private struct SubscriptionRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ReorderContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct SubscriptionListViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum ReorderAutoScrollDirection: Equatable {
    case none
    case up
    case down
}

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onPanelSizeChange: (PanelSize) -> Void
    @State private var confirmQuit = false
    @State private var isReordering = false
    @State private var subscriptionListContentHeight: CGFloat = PanelLayoutMetrics.subscriptionListMaxHeight
    @State private var subscriptionListViewportHeight: CGFloat = PanelLayoutMetrics.subscriptionListMaxHeight
    /// 排序模式（DragGesture）状态。拖动期间不改动 store 数组，全部视觉换位由行 offset 承担，
    /// 消除「系统重排动画 + 手动 offset」双通道造成的抖动；松手才一次性写回 store。
    /// reorderSequence 是拖动中的「视觉序列」（含拖行当前槽），仅驱动让位 offset。
    @State private var reorderDraggingID: UUID?
    @State private var reorderTranslation: CGFloat = 0
    @State private var reorderOriginMidY: CGFloat = 0
    @State private var reorderSequence: [UUID] = []
    @State private var reorderFrames: [UUID: CGRect] = [:]
    @State private var reorderBaseFrames: [UUID: CGRect] = [:]
    @State private var reorderPointerY: CGFloat = 0
    @State private var reorderContentFrame: CGRect = .zero
    @State private var reorderAutoScrollDirection: ReorderAutoScrollDirection = .none
    @State private var reorderAutoScrollTick = 0
    private static let subscriptionListViewportCoordinateSpace = "subscriptionListViewport"
    private static let subscriptionListContentCoordinateSpace = "subscriptionListContent"
    private static let reorderSpacing: CGFloat = 8
    private static let reorderEdgeActivation: CGFloat = 48
    private static let reorderAutoScrollInterval: UInt64 = 80_000_000
    #if DEBUG
    @State private var previewMode: StatusPreviewMode?
    #endif

    init(onPanelSizeChange: @escaping (PanelSize) -> Void = { _ in }) {
        self.onPanelSizeChange = onPanelSizeChange
    }

    private func navigateForward(_ action: () -> Void) {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2), action)
    }

    private func navigateBack() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
            navigation.returnToOverview()
        }
    }

    private var pushTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
    }

    private func openSettings() {
        navigateForward { navigation.route = .settings }
    }
    private func openAddSubscription() {
        navigateForward { navigation.beginAdding() }
    }

    private func openEditor(for subscription: Subscription) {
        navigateForward { navigation.beginEditingConfiguration(subscription) }
    }

    var body: some View {
        Group {
            switch navigation.content(for: store.subscriptions) {
            case .overview:
                dashboardContent.transition(pushTransition)
            case .settings:
                SettingsPanel(settings: store.settings, onBack: navigateBack, onPreview: previewEntryAction)
                    .transition(pushTransition)
            case .addProvider:
                ProviderSelectionPage(onBack: navigateBack) { platform in
                    navigateForward { navigation.selectProvider(platform) }
                }
                .transition(pushTransition)
            case .addConfiguration(let draft):
                SubscriptionEditorSheet(draft: draft, onClose: navigateBack)
                    .transition(pushTransition)
            case .editConfiguration(let draft, let subscription):
                SubscriptionEditorSheet(draft: draft, subscription: subscription, onClose: navigateBack)
                    .transition(pushTransition)
            case .recovery:
                NavigationRecoveryView(onReturn: navigateBack).transition(pushTransition)
            }
        }
        .id(routeContentID)
        .padding(.horizontal, TM.panelHorizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(width: navigation.panelSize.width, height: navigation.panelSize.height)
        .onPreferenceChange(PanelHeightPreferenceKey.self) { measurement in
            guard let measurement else { return }
            navigation.reportMeasuredHeight(measurement.height, for: measurement.route)
        }
        .background(TMPanelBackground())
        .foregroundStyle(TM.textPrimary)
        .modifier(TMColorSchemeModifier(mode: store.settings.appearanceMode))
        .overlay(alignment: .bottom) {
            if navigation.route == .overview {
                PanelHeightResizeHandle(
                    panelHeight: CGFloat(navigation.panelSize.height),
                    onChanged: { navigation.setUserOverviewHeight($0, persist: false) },
                    onEnded: { navigation.setUserOverviewHeight($0, persist: true) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 8)
                .accessibilityHidden(true)
            }
        }
        #if DEBUG
        .overlay {
            if let previewMode {
                StatusPreviewOverlay(mode: previewMode) {
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { self.previewMode = nil }
                }
                .transition(.opacity)
            }
        }
        #endif
        .overlay {
            if confirmQuit {
                ConfirmDialog(
                    title: "退出 TokenMeter？",
                    message: "退出后将停止后台刷新。",
                    confirmTitle: "退出 TokenMeter",
                    onConfirm: {
                        confirmQuit = false
                        store.stop()
                        DispatchQueue.main.async {
                            NSApplication.shared.terminate(nil)
                        }
                    },
                    onCancel: {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { confirmQuit = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay {
            PanelWindowAppearanceBridge(appearanceMode: store.settings.appearanceMode)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .onAppear { onPanelSizeChange(navigation.panelSize) }
        .onChange(of: navigation.panelSize) { _, size in onPanelSizeChange(size) }
        .onChange(of: store.settings.autoRefreshEnabled) { _, enabled in
            if enabled { store.start() } else { store.stop() }
        }
    }

    private var routeContentID: String {
        switch navigation.route {
        case .overview: "overview"
        case .settings: "settings"
        case .addProvider: "add-provider"
        case .addConfiguration: "add-configuration"
        case .editConfiguration(let id): "edit-configuration-\(id.uuidString)"
        }
    }
    private var dashboardContent: some View {
        return VStack(alignment: .leading, spacing: 0) {
            DashboardHeader(
                meta: dashboardMeta,
                isRefreshing: store.isRefreshing,
                onRefresh: { Task { await store.refreshAll(source: .manual) } },
                onSettings: {
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) { openSettings() }
                },
                isReordering: isReordering,
                onToggleReorder: store.subscriptions.count > 1 ? { toggleReordering() } : nil
            )
            .padding(.bottom, 10)

            if store.subscriptions.isEmpty {
                MenuBarEmptyState { openAddSubscription() }
                    .frame(
                        maxHeight: navigation.hasManualOverviewHeight ? .infinity : nil,
                        alignment: .top
                    )
            } else {
                if isReordering {
                    reorderHint
                        .padding(.bottom, 8)
                }
                subscriptionList
            }

            footer
        }
        .onPreferenceChange(SubscriptionListContentHeightPreferenceKey.self) { measured in
            // 保存完整内容高度；自动模式使用固定上限，手动高度模式由父容器决定 viewport。
            guard measured > 0 else { return }
            let spacing = CGFloat(max(store.subscriptions.count - 1, 0)) * 8
            subscriptionListContentHeight = measured + spacing
        }
        .onPreferenceChange(SubscriptionListViewportHeightPreferenceKey.self) { measured in
            guard measured > 0 else { return }
            subscriptionListViewportHeight = measured
        }
        .onPreferenceChange(SubscriptionRowFramePreferenceKey.self) { frames in
            // 让位 offset 会改变渲染 frame；拖动期间固定基准，避免几何测量和
            // offset 互相反馈导致换位抖动。
            if reorderDraggingID == nil {
                reorderFrames = frames
            } else if reorderBaseFrames.isEmpty, frames.count == store.subscriptions.count {
                reorderBaseFrames = frames
            }
        }
        .onPreferenceChange(ReorderContentFramePreferenceKey.self) { frame in
            reorderContentFrame = frame
            guard reorderDraggingID != nil else { return }
            adjustReorderSequence(centerY: reorderPointerY - frame.minY)
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.15), value: isReordering)
        .reportsIntrinsicPanelHeight(route: .overview, chrome: PanelLayoutMetrics.rootVerticalChrome)
        .onDisappear {
            isReordering = false
            resetReorderState()
        }
    }

    private var reorderHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TM.accent)
            Text("拖动卡片调整顺序")
                .font(.system(size: 10))
                .foregroundStyle(TM.textSecondary)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var subscriptionListIdealHeight: CGFloat {
        min(subscriptionListContentHeight, PanelLayoutMetrics.subscriptionListMaxHeight)
    }

    /// 订阅卡片列表。列表行高度由卡片内容测量驱动，超限时内部滚动；
    /// 排序模式改用纯 DragGesture 实时换位，避免系统拖放链在瞬态面板中
    /// 与滚动手势和布局更新互相竞争。
    private var subscriptionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.reorderSpacing) {
                    ForEach(store.subscriptions) { subscription in
                        subscriptionRow(for: subscription)
                            .id(subscription.id)
                    }
                }
                .coordinateSpace(name: Self.subscriptionListContentCoordinateSpace)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ReorderContentFramePreferenceKey.self,
                            value: geometry.frame(in: .named(Self.subscriptionListViewportCoordinateSpace))
                        )
                    }
                }
            }
            .coordinateSpace(name: Self.subscriptionListViewportCoordinateSpace)
            .scrollIndicators(.hidden)
            .frame(
                idealHeight: subscriptionListIdealHeight,
                maxHeight: navigation.hasManualOverviewHeight ? .infinity : subscriptionListIdealHeight
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SubscriptionListViewportHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            .padding(.vertical, 2)
            .task(id: reorderAutoScrollDirection) {
                guard reorderAutoScrollDirection != .none else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.reorderAutoScrollInterval)
                    guard !Task.isCancelled else { return }
                    reorderAutoScrollTick &+= 1
                }
            }
            .onChange(of: reorderAutoScrollTick) { _, _ in
                advanceAutoScroll(using: proxy)
            }
        }
    }

    @ViewBuilder
    private func subscriptionRow(for subscription: Subscription) -> some View {
        let isDragging = reorderDraggingID == subscription.id
        let row = subscriptionCard(for: subscription)
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: SubscriptionListContentHeightPreferenceKey.self, value: proxy.size.height)
                    .preference(
                        key: SubscriptionRowFramePreferenceKey.self,
                        value: [subscription.id: proxy.frame(in: .named(Self.subscriptionListContentCoordinateSpace))]
                    )
            })
            .zIndex(isDragging ? 1 : 0)

        if isReordering {
            let offsetRow = row
                .offset(y: reorderOffsetY(for: subscription.id))
                .contentShape(Rectangle())
                // ScrollView 在 macOS 上仍可能参与纵向手势，排序手势必须优先。
                .highPriorityGesture(reorderDragGesture(for: subscription.id))
                // 拖行跟手更新不动画，让位行只在序列改变时短暂缓动。
                .animation(
                    isDragging || reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: reorderSequence
                )
            offsetRow
        } else {
            row
        }
    }

    private func subscriptionCard(for subscription: Subscription) -> some View {
        SubscriptionMenuCard(
            subscription: subscription,
            snapshot: store.snapshots[subscription.id],
            onEdit: { openEditor(for: subscription) },
            isReordering: isReordering
        )
    }

    /// 行在视觉序列 reorderSequence（目标布局，内容坐标）下的顶部 y。
    private func reorderVisualTop(for id: UUID) -> CGFloat? {
        let frames = activeReorderFrames
        guard let listTop = frames.values.map(\.minY).min() else { return nil }
        var top = listTop
        for seqID in reorderSequence {
            guard let frame = frames[seqID] else { return nil }
            if seqID == id { return top }
            top += frame.height + Self.reorderSpacing
        }
        return nil
    }

    /// 排序行的纵向 offset：
    /// - 拖动行：布局槽静止，offset = 跟手位移（视觉中心 = 起始中线 + translation）。
    /// - 让位行：从 store 布局槽让位到视觉序列槽（拖动期间 store 数组不变，布局静止）。
    private func reorderOffsetY(for id: UUID) -> CGFloat {
        guard isReordering, reorderDraggingID != nil else { return 0 }
        if reorderDraggingID == id {
            if let frame = activeReorderFrames[id], !reorderContentFrame.isEmpty {
                return reorderPointerY - (reorderContentFrame.minY + frame.midY)
            }
            return reorderTranslation
        }
        guard let visualTop = reorderVisualTop(for: id), let layoutTop = activeReorderFrames[id]?.minY else { return 0 }
        return visualTop - layoutTop
    }

    private var activeReorderFrames: [UUID: CGRect] {
        reorderBaseFrames.isEmpty ? reorderFrames : reorderBaseFrames
    }

    private func resetReorderState() {
        reorderDraggingID = nil
        reorderTranslation = 0
        reorderOriginMidY = 0
        reorderSequence = []
        reorderBaseFrames = [:]
        reorderPointerY = 0
        reorderContentFrame = .zero
        reorderAutoScrollDirection = .none
    }

    private func reorderDragGesture(for id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.subscriptionListViewportCoordinateSpace))
            .onChanged { value in
                guard reorderDraggingID == nil || reorderDraggingID == id else { return }
                if reorderDraggingID == nil {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        // 有基准 frame 时按卡片中线换位；测量稍晚时退回 startLocation，
                        // 先保证手势可以开始，后续 frame 到位后再参与换位。
                        reorderDraggingID = id
                        reorderOriginMidY = reorderFrames[id]?.midY ?? value.startLocation.y
                        reorderSequence = store.subscriptions.map(\.id)
                        reorderBaseFrames = reorderFrames
                    }
                }
                reorderPointerY = value.location.y
                reorderTranslation = value.translation.height
                let centerY = reorderContentFrame.isEmpty
                    ? reorderOriginMidY + value.translation.height
                    : value.location.y - reorderContentFrame.minY
                adjustReorderSequence(centerY: centerY)
                updateAutoScrollDirection(for: value.location.y)
            }
            .onEnded { _ in
                finishReorder()
            }
    }

    private func updateAutoScrollDirection(for pointerY: CGFloat) {
        guard reorderContentFrame.isEmpty || reorderContentFrame.height > subscriptionListViewportHeight + 1 else {
            reorderAutoScrollDirection = .none
            return
        }
        let top = Self.reorderEdgeActivation
        let bottom = subscriptionListViewportHeight - Self.reorderEdgeActivation
        let direction: ReorderAutoScrollDirection
        if pointerY < top {
            direction = .up
        } else if pointerY > bottom {
            direction = .down
        } else {
            direction = .none
        }
        if direction != reorderAutoScrollDirection {
            reorderAutoScrollDirection = direction
        }
    }

    private func advanceAutoScroll(using proxy: ScrollViewProxy) {
        guard isReordering,
              reorderAutoScrollDirection != .none,
              let dragID = reorderDraggingID,
              var index = reorderSequence.firstIndex(of: dragID)
        else { return }

        let step: Int = reorderAutoScrollDirection == .down ? 1 : -1
        let nextIndex = index + step
        guard reorderSequence.indices.contains(nextIndex) else {
            reorderAutoScrollDirection = .none
            return
        }

        let previousSequence = reorderSequence
        let centerY = reorderContentFrame.isEmpty
            ? reorderOriginMidY + reorderTranslation
            : reorderPointerY - reorderContentFrame.minY
        adjustReorderSequence(centerY: centerY)
        index = reorderSequence.firstIndex(of: dragID) ?? index

        let targetIndex = index + step
        guard reorderSequence.indices.contains(targetIndex) else {
            reorderAutoScrollDirection = .none
            return
        }
        if reorderSequence == previousSequence {
            reorderSequence.swapAt(index, targetIndex)
        }

        let revealIndex = reorderAutoScrollDirection == .down
            ? min(targetIndex + 1, reorderSequence.count - 1)
            : max(targetIndex - 1, 0)
        let revealID = reorderSequence[revealIndex]
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.12)
        withAnimation(animation) {
            proxy.scrollTo(revealID, anchor: reorderAutoScrollDirection == .down ? .bottom : .top)
        }
    }

    /// 拖动中视觉让位：只调整 reorderSequence（不动 store），使拖行在序列中的槽位贴近鼠标中心。
    /// 比较对象是各行在目标序列中的中线（静态几何），不受让位动画瞬时位置影响，判定稳定。
    private func adjustReorderSequence(centerY: CGFloat) {
        guard let dragID = reorderDraggingID else { return }
        var seq = reorderSequence
        guard var k = seq.firstIndex(of: dragID) else { return }
        let frames = activeReorderFrames
        guard frames.count == seq.count, seq.allSatisfy({ frames[$0] != nil }) else { return }
        func centerYInSequence(_ id: UUID, in s: [UUID]) -> CGFloat {
            var top = frames.values.map(\.minY).min() ?? 0
            for sid in s {
                guard let frame = frames[sid] else { return top }
                if sid == id { return top + frame.height / 2 }
                top += frame.height + Self.reorderSpacing
            }
            return top
        }
        while k > 0, centerY < centerYInSequence(seq[k - 1], in: seq) {
            seq.swapAt(k, k - 1)
            k -= 1
        }
        while k < seq.count - 1, centerY > centerYInSequence(seq[k + 1], in: seq) {
            seq.swapAt(k, k + 1)
            k += 1
        }
        if seq != reorderSequence { reorderSequence = seq }
    }

    /// 松手落位：把视觉序列一次性写回 store（数组 move + 持久化）并复位拖行状态。
    /// 拖动期间让位 offset 恰把各行显示在最终槽位，落位动画只是拖行从跟手处平滑归槽，
    /// 无「系统重排动画 + offset」双通道，不抖。
    private func finishReorder() {
        guard let dragID = reorderDraggingID else { return }
        let sourceIndex = store.subscriptions.firstIndex(where: { $0.id == dragID })
        let targetIndex = reorderSequence.firstIndex(of: dragID)
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.18)) {
            if let sourceIndex, let targetIndex, sourceIndex != targetIndex {
                // Array.move 的 destination 是插入点；向下移动时需跳过被移除的原槽位。
                let destination = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
                store.moveSubscriptions(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
            }
            reorderDraggingID = nil
            reorderTranslation = 0
            reorderOriginMidY = 0
            reorderSequence = store.subscriptions.map(\.id)
            reorderBaseFrames = [:]
            reorderPointerY = 0
            reorderContentFrame = .zero
            reorderAutoScrollDirection = .none
        }
    }

    private func toggleReordering() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
            if isReordering {
                // 退出排序：store 已是最新顺序，仅复位视觉状态。
                resetReorderState()
            } else {
                reorderSequence = store.subscriptions.map(\.id)
                reorderBaseFrames = [:]
            }
            isReordering.toggle()
        }
    }

    private var dashboardMeta: String {
        let count = store.subscriptions.count
        let updated = store.lastRefreshAt.map { " · \($0.tokenMeterTimeText) 更新" } ?? ""
        return "\(count) 个服务\(updated)"
    }

    private var footer: some View {
        HStack(spacing: 10) {
                Button { openAddSubscription() } label: {
                    Label("添加订阅", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TM.textPrimary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("添加订阅")
                .accessibilityLabel("添加订阅")

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Circle().fill(store.isRefreshing ? TM.accent : TM.ok).frame(width: 6, height: 6)
                    Text(store.isRefreshing ? "同步中…" : (store.lastRefreshAt.map { _ in "已同步" } ?? "等待同步"))
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textTertiary)
                }

                Button(role: .destructive) {
                    confirmQuit = true
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TM.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("退出 TokenMeter")
                .accessibilityLabel("退出 TokenMeter")
            }
            .padding(.top, 6)
    }

    private var previewEntryAction: () -> Void {
        #if DEBUG
        return {
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { previewMode = .normal }
        }
        #else
        return {}
        #endif
    }
}

private struct ProviderSelectionPage: View {
    let onBack: () -> Void
    let onSelect: (Platform) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HeaderIconButton(systemName: "chevron.left", label: "返回概览", action: onBack)
                VStack(alignment: .leading, spacing: 2) {
                    Text("选择供应商")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.5)
                    Text("选择要连接的 AI 服务")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                }
                Spacer()
            }
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Platform.allCases) { platform in
                        ProviderSelectionCard(platform: platform) { onSelect(platform) }
                    }
                }
                .padding(.vertical, 8)
                .reportsIntrinsicPanelHeight(route: .addProvider, chrome: PanelLayoutMetrics.measuredProviderChrome)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ProviderSelectionCard: View {
    let platform: Platform
    let action: () -> Void
    @State private var hovering = false

    private var authenticationSummary: String {
        platform == .kimi
            ? "API Key、Kimi Code OAuth 或网页登录态"
            : "API Key · \(platform.capabilityDescription)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PlatformLogo(platform: platform, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(platform.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TM.textPrimary)
                    Text(authenticationSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TM.textTertiary)
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 11)
            .background(hovering ? TM.cardFillHover : TM.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? TM.borderStrong : TM.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(platform.rawValue)，\(authenticationSummary)")
    }
}

private struct DashboardHeader: View {
    let meta: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void
    var isReordering: Bool = false
    var onToggleReorder: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 额度")
                    .font(.system(size: 20, weight: .semibold).width(.standard))
                    .tracking(-0.5)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            }

            Spacer()

            if let onToggleReorder {
                HeaderIconButton(
                    systemName: isReordering ? "checkmark" : "line.3.horizontal",
                    label: isReordering ? "完成排序" : "排序",
                    isActive: isReordering,
                    action: onToggleReorder
                )
            }

            HeaderIconButton(systemName: "arrow.clockwise", label: "刷新全部", rotation: spinning && !reduceMotion ? 360 : 0, action: onRefresh)
            .disabled(isRefreshing)
            .opacity(isRefreshing ? 0.6 : 1)
            .onChange(of: isRefreshing) { _, refreshing in
                if refreshing && !reduceMotion {
                    spinning = false
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
                } else {
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { spinning = false }
                }
            }

            HeaderIconButton(systemName: "slider.horizontal.3", label: "设置", action: onSettings)
        }
    }
}

/// 34pt 见方的幽灵图标按钮，悬停轻微提亮；rotation 用于刷新旋转反馈。
struct HeaderIconButton: View {
    let systemName: String
    let label: String
    var rotation: Double = 0
    var isActive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(isActive ? TM.accent : (hovering ? TM.textPrimary : TM.textSecondary))
                .frame(width: 32, height: 32)
                .background(isActive || hovering ? TM.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hovering ? TM.border : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - 空状态

private struct MenuBarEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 34)
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(TM.textPrimary.opacity(0.85))
                .frame(width: 56, height: 56)
                .background(TM.hoverFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TM.border, lineWidth: 1))
            Text("集中查看 AI 用量")
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.3)
                .padding(.top, 16)
            Text("添加 DeepSeek、Kimi 或其他服务，随时查看余额与用量。")
                .font(.system(size: 11))
                .foregroundStyle(TM.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.top, 6)
            Button(action: onAdd) {
                Label("添加订阅", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0x191A1A))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(hex: 0xE9EBE8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .help("添加订阅")
            .accessibilityLabel("添加订阅")
            Spacer(minLength: 30)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 订阅卡片

private struct SubscriptionMenuCard: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot?
    let onEdit: () -> Void
    var isReordering: Bool = false

    @State private var hovering = false

    private var status: QuotaStatus? {
        guard let snapshot else { return nil }
        return SubscriptionCardPresentation.cardIndicatorStatus(snapshot: snapshot, subscription: subscription)
    }

    private var cardAnchor: SubscriptionCardPresentation.Anchor? {
        guard let snapshot else { return nil }
        return SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot)
    }

    private var accessibilityLabel: String {
        SubscriptionCardPresentation.cardAccessibilityLabel(
            subscription: subscription,
            snapshot: snapshot,
            anchor: cardAnchor
        )
    }

    var body: some View {
        // 排序模式下卡片不能是 Button：Button 会消费鼠标按下，行级手势
        // （排序 DragGesture）收不到事件。此时改用非交互容器渲染卡片外观，
        // 拖拽手势由外层行视图捕获。
        Group {
            if isReordering {
                cardContent
            } else {
                Button(action: onEdit) { cardContent }
                    .buttonStyle(.plain)
            }
        }
        .tmCard(hovering: hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(isReordering ? "拖动排序" : "编辑配置")
        .accessibilityLabel(accessibilityLabel)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                PlatformLogo(platform: subscription.platform, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(subscription.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let status {
                            Circle()
                                .fill(status == .normal ? TM.ok : (status == .warning ? TM.warn : TM.danger))
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(status.label)
                        }
                    }
                    Text("\(subscription.platform.rawValue) · \(subscription.authMethod.label)")
                        .font(.system(size: 9))
                        .foregroundStyle(TM.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(0)

                Spacer(minLength: 8)

                if let anchor = cardAnchor {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(anchor.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TM.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(0)
                        Text(anchor.value)
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(anchor.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    .layoutPriority(1)
                }

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TM.textTertiary)
                    .frame(width: isReordering ? 18 : 0)
                    .opacity(isReordering ? 1 : 0)
                    .accessibilityHidden(true)
            }

            cardBody
        }
        .padding(.horizontal, TM.cardContentHorizontal)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cardBody: some View {
        if let snapshot, SubscriptionCardPresentation.showsRealtimeUsageBody(for: snapshot) {
            SubscriptionUsageView(subscription: subscription, snapshot: snapshot)
        } else if let snapshot {
            stateRow(for: snapshot)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("等待首次刷新…")
            }
            .font(.system(size: 11))
            .foregroundStyle(TM.textSecondary)
        }
    }

    @ViewBuilder
    private func stateRow(for snapshot: UsageSnapshot) -> some View {
        switch snapshot.state {
        case .authenticationRequired:
            cardStateRow(icon: "person.crop.circle.badge.exclamationmark", tint: TM.warn,
                         title: "认证已失效", detail: "前往编辑页面重新连接")
        case .notConfigured:
            cardStateRow(icon: "lock.trianglebadge.exclamationmark", tint: TM.warn,
                         title: "需要配置", detail: snapshot.errorMessage ?? "前往编辑页面完成配置")
        case .unsupported:
            cardStateRow(icon: "questionmark.circle", tint: TM.textSecondary,
                         title: "暂不支持额度接口", detail: snapshot.errorMessage ?? "")
        case .error:
            cardStateRow(icon: "exclamationmark.triangle", tint: TM.danger,
                         title: "获取失败", detail: snapshot.errorMessage ?? "请稍后重试")
        case .realtime:
            EmptyView()
        }
    }

    private func cardStateRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
private enum StatusPreviewMode: String, CaseIterable, Identifiable {
    case normal, loading, authenticationRequired, error, lowBalance, empty

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: "正常连接"
        case .loading: "正在更新"
        case .authenticationRequired: "认证已过期"
        case .error: "网络错误"
        case .lowBalance: "余额偏低"
        case .empty: "空状态"
        }
    }
}

private struct StatusPreviewOverlay: View {
    let mode: StatusPreviewMode
    let onClose: () -> Void

    @State private var current: StatusPreviewMode

    init(mode: StatusPreviewMode, onClose: @escaping () -> Void) {
        self.mode = mode
        self.onClose = onClose
        _current = State(initialValue: mode)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("预览组件状态")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TM.textSecondary)
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭预览")
                    .accessibilityLabel("关闭预览")
                }
                Text("仅本地示例，不修改任何真实数据。")
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(StatusPreviewMode.allCases) { item in
                        Button { current = item } label: {
                            Text(item.label)
                                .font(.system(size: 10, weight: item == current ? .semibold : .regular))
                                .foregroundStyle(item == current ? TM.textPrimary : TM.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(item == current ? TM.cardFillHover : TM.cardFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(item == current ? TM.borderStrong : TM.border, lineWidth: 1))
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                previewContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 130)
            }
            .padding(14)
            .background(TM.panelMid, in: UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous))
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                    .strokeBorder(TM.borderStrong, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch current {
        case .empty:
            MenuBarEmptyState {}
                .scaleEffect(0.92, anchor: .top)
        case .loading:
            VStack(spacing: 10) {
                SubscriptionMenuCard(subscription: Self.deepSeek, snapshot: nil, onEdit: {})
                SubscriptionMenuCard(subscription: Self.kimi, snapshot: nil, onEdit: {})
            }
        case .normal:
            VStack(spacing: 10) {
                SubscriptionMenuCard(subscription: Self.deepSeek, snapshot: Self.normalDeepSeek, onEdit: {})
                SubscriptionMenuCard(subscription: Self.kimi, snapshot: Self.normalKimi, onEdit: {})
            }
        case .authenticationRequired:
            SubscriptionMenuCard(subscription: Self.kimi, snapshot: Self.authExpiredKimi, onEdit: {})
        case .error:
            SubscriptionMenuCard(subscription: Self.deepSeek, snapshot: Self.errorDeepSeek, onEdit: {})
        case .lowBalance:
            SubscriptionMenuCard(subscription: Self.deepSeek, snapshot: Self.lowDeepSeek, onEdit: {})
        }
    }

    private static let deepSeek = Subscription(platform: .deepSeek, name: "DeepSeek", authMethod: .manualAPIKey)
    private static let kimi = Subscription(platform: .kimi, name: "Kimi", authMethod: .kimiOAuth)

    private static func balanceQuota(remaining: Double) -> Quota {
        Quota(name: "API 余额", used: 100 - remaining, limit: 100, resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance)
    }

    private static var normalDeepSeek: UsageSnapshot {
        .realtime(subscription: deepSeek, quotas: [balanceQuota(remaining: 18.42)])
    }

    private static var lowDeepSeek: UsageSnapshot {
        .realtime(subscription: deepSeek, quotas: [balanceQuota(remaining: 2.10)])
    }

    private static var errorDeepSeek: UsageSnapshot {
        .failure(subscription: deepSeek, message: "网络请求超时，请稍后重试")
    }

    private static var authExpiredKimi: UsageSnapshot {
        UsageSnapshot(
            subscriptionID: kimi.id,
            platform: .kimi,
            quotas: [],
            updatedAt: .now,
            isDemo: false,
            errorMessage: "OAuth 令牌已过期",
            state: .authenticationRequired
        )
    }

    private static var normalKimi: UsageSnapshot {
        .realtime(
            subscription: kimi,
            quotas: [
                Quota(name: "5 小时额度", used: 82, limit: 100, resetAt: .now.addingTimeInterval(7200), kind: .fiveHour),
                Quota(name: "每周额度", used: 64, limit: 100, resetAt: .now.addingTimeInterval(86400 * 2), kind: .weekly)
            ],
            overallUsageRatio: 0.41
        )
    }
}
#endif

/// 面板内确认对话框：模态遮罩 + 卡片，避免 SwiftUI .alert 在瞬态面板
/// 中弹独立系统窗口，导致面板被外部点击逻辑关闭。
struct ConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消", action: onCancel)
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(TM.danger)
                }
            }
            .padding(14)
            .frame(maxWidth: 250)
            .background(TM.panelMid, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TM.borderStrong, lineWidth: 1))
        }
    }
}

private struct NavigationRecoveryView: View {
    let onReturn: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 30))
                .foregroundStyle(TM.warn)
            Text("编辑页面已不可用")
                .font(.system(size: 16, weight: .semibold))
            Text("该订阅已被移除或编辑状态已过期。返回概览后可重新选择订阅。")
                .font(.system(size: 11))
                .foregroundStyle(TM.textSecondary)
                .multilineTextAlignment(.center)
            Button("返回概览", action: onReturn)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
