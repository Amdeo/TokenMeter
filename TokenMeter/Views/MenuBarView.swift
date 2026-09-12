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

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onPanelSizeChange: (PanelSize) -> Void
    @State private var confirmQuit = false
    @State private var isReordering = false
    @State private var subscriptionListContentHeight: CGFloat = PanelLayoutMetrics.subscriptionListMaxHeight
    @State private var subscriptionListViewportHeight: CGFloat = PanelLayoutMetrics.subscriptionListMaxHeight
    /// 排序模式（DragGesture）状态机：拖动期间不改动 store 数组，全部视觉换位由行 offset 承担，
    /// 消除「系统重排动画 + 手动 offset」双通道造成的抖动；松手才一次性写回 store。
    @State private var reorder = SubscriptionReorderController()
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
            : .move(edge: .trailing).combined(with: .opacity)
    }


    var body: some View {
        Group {
            switch navigation.content(for: store.subscriptions) {
            case .overview:
                dashboardContent.transition(pushTransition)
            case .settings:
                SettingsPanel(
                    settings: store.settings,
                    onBack: navigateBack,
                    onMigration: { navigateForward { navigation.route = .migration } },
                    migrationRecoveryError: store.lastMigrationRecoveryError,
                    persistenceError: store.lastPersistenceError,
                    onPreview: previewEntryAction
                )
                .transition(pushTransition)
            case .migration:
                MigrationPanel(store: store, onClose: closeMigration)
                    .transition(pushTransition)
            case .addProvider:
                ProviderSelectionPage(onBack: navigateBack) { providerID in
                    navigateForward { navigation.selectProvider(providerID) }
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
        .id(navigation.route)
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

    private var dashboardContent: some View {
        return VStack(alignment: .leading, spacing: 0) {
            DashboardHeader(
                meta: dashboardMeta,
                isRefreshing: store.isRefreshing,
                onRefresh: { store.refreshAll(source: .manual) },
                onSettings: {
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) { openSettings() }
                },
                isReordering: isReordering,
                onToggleReorder: store.subscriptions.count > 1 ? { toggleReordering() } : nil
            )
            .padding(.bottom, 10)

            if let error = store.lastPersistenceError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                Button("重新读取配置") { store.retryLoadingSubscriptions() }
                    .font(.system(size: 11))
                    .padding(.bottom, 8)
            }
            if !store.subscriptions.isEmpty,
               store.settings.notificationStatus == .notDetermined,
               store.settings.lowBalanceAlerts || store.settings.authenticationAlerts || store.settings.serviceErrorAlerts {
                VStack(alignment: .leading, spacing: 6) {
                    Text("提醒尚未获得系统授权。允许后才能接收余额与认证提醒。")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                    Button("允许本地通知") { store.settings.requestNotificationsIfNeeded() }
                        .font(.system(size: 11))
                }
                .padding(.bottom, 8)
            }

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
            if reorder.draggingID == nil {
                reorder.frames = frames
            } else if reorder.baseFrames.isEmpty, frames.count == store.subscriptions.count {
                reorder.baseFrames = frames
            }
        }
        .onPreferenceChange(ReorderContentFramePreferenceKey.self) { frame in
            reorder.contentFrame = frame
            guard reorder.draggingID != nil else { return }
            reorder.adjustSequence(centerY: reorder.pointerY - frame.minY)
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.15), value: isReordering)
        .reportsIntrinsicPanelHeight(route: .overview, chrome: PanelLayoutMetrics.rootVerticalChrome)
        .onDisappear {
            isReordering = false
            reorder.reset()
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
                VStack(spacing: SubscriptionReorderController.spacing) {
                    ForEach(store.subscriptions) { subscription in
                        subscriptionRow(for: subscription)
                            .id(subscription.id)
                    }
                }
                .coordinateSpace(name: SubscriptionReorderController.contentCoordinateSpace)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ReorderContentFramePreferenceKey.self,
                            value: geometry.frame(in: .named(SubscriptionReorderController.viewportCoordinateSpace))
                        )
                    }
                }
            }
            .coordinateSpace(name: SubscriptionReorderController.viewportCoordinateSpace)
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
            .task(id: reorder.autoScrollDirection) {
                guard reorder.autoScrollDirection != .none else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: SubscriptionReorderController.autoScrollInterval)
                    guard !Task.isCancelled else { return }
                    reorder.autoScrollTick &+= 1
                }
            }
            .onChange(of: reorder.autoScrollTick) { _, _ in
                reorder.advanceAutoScroll(using: proxy, viewportHeight: subscriptionListViewportHeight, reduceMotion: reduceMotion)
            }
        }
    }

    @ViewBuilder
    private func subscriptionRow(for subscription: Subscription) -> some View {
        let isDragging = reorder.draggingID == subscription.id
        let row = subscriptionCard(for: subscription)
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: SubscriptionListContentHeightPreferenceKey.self, value: proxy.size.height)
                    .preference(
                        key: SubscriptionRowFramePreferenceKey.self,
                        value: [subscription.id: proxy.frame(in: .named(SubscriptionReorderController.contentCoordinateSpace))]
                    )
            })
            .zIndex(isDragging ? 1 : 0)

        if isReordering {
            let offsetRow = row
                .offset(y: reorder.offsetY(for: subscription.id))
                .contentShape(Rectangle())
                // ScrollView 在 macOS 上仍可能参与纵向手势，排序手势必须优先。
                .highPriorityGesture(reorder.dragGesture(
                    for: subscription.id,
                    subscriptions: store.subscriptions,
                    viewportHeight: subscriptionListViewportHeight,
                    onCommit: { _, sourceIndex, targetIndex in
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.18)) {
                            // Array.move 的 destination 是插入点；向下移动时需跳过被移除的原槽位。
                            let destination = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
                            store.moveSubscriptions(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
                        }
                    }
                ))
                // 拖行跟手更新不动画，让位行只在序列改变时短暂缓动。
                .animation(
                    isDragging || reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: reorder.sequence
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


    private func toggleReordering() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
            if isReordering {
                // 退出排序：store 已是最新顺序，仅复位视觉状态。
                reorder.reset()
            } else {
                reorder.sequence = store.subscriptions.map(\.id)
                reorder.baseFrames = [:]
            }
            isReordering.toggle()
        }
    }

    private var dashboardMeta: String {
        "\(store.subscriptions.count) 个服务"
    }

    private func synchronizationStatus(now: Date) -> (text: String, color: Color) {
        if store.isRefreshing { return ("同步中…", TM.accent) }
        let enabled = store.subscriptions.filter(\.isEnabled)
        guard !enabled.isEmpty else { return ("暂无启用服务", TM.textTertiary) }
        let snapshots = enabled.compactMap { store.snapshots[$0.id] }
        let failed = snapshots.filter { $0.state != .realtime }.count
        if failed == enabled.count { return ("全部获取失败", TM.danger) }
        if failed > 0 { return ("\(failed) 个服务获取失败", TM.warn) }
        guard snapshots.count == enabled.count,
              let oldest = snapshots.map(\.updatedAt).min() else {
            return ("等待同步", TM.textTertiary)
        }
        if now.timeIntervalSince(oldest) > max(120, store.settings.refreshInterval * 2) {
            return ("数据已过期", TM.warn)
        }
        return ("已同步 · \(oldest.formatted(date: .omitted, time: .shortened))", TM.ok)
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

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let status = synchronizationStatus(now: context.date)
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                        Text(status.text)
                            .font(.system(size: 10))
                            .foregroundStyle(TM.textTertiary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
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

private extension MenuBarView {
    func openSettings() {
        navigateForward { navigation.route = .settings }
    }

    func openAddSubscription() {
        navigateForward { navigation.beginAdding() }
    }

    func openEditor(for subscription: Subscription) {
        navigateForward { navigation.beginEditingConfiguration(subscription) }
    }

    func closeMigration() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
            navigation.returnToSettings()
        }
    }
}

private struct ProviderSelectionPage: View {
    let onBack: () -> Void
    let onSelect: (ProviderID) -> Void

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
                    ForEach(ProviderRegistry.all, id: \.id) { definition in
                        ProviderSelectionCard(definition: definition) { onSelect(definition.id) }
                    }
                }
                .padding(.vertical, 8)
                .reportsIntrinsicPanelHeight(route: .addProvider, chrome: PanelLayoutMetrics.providerChrome)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ProviderSelectionCard: View {
    let definition: any ProviderDefinition
    let action: () -> Void
    @State private var hovering = false

    private var metadata: ProviderMetadata { definition.metadata }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PlatformLogo(definition: definition, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(metadata.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TM.textPrimary)
                    Text(metadata.authenticationSummary)
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
        .accessibilityLabel("\(metadata.displayName)，\(metadata.authenticationSummary)")
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
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(TM.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

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
