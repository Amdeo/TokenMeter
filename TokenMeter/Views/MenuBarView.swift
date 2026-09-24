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
    static let panelHorizontal: CGFloat = 8
    /// 卡片/设置行/表单行内部的统一水平内边距（对齐主页订阅卡片的 11pt）。
    static let cardContentHorizontal: CGFloat = 11
    /// macOS `List` 会在每行两侧内建 8pt 内缩；概览页反向抵消后才能与其他页面同宽同位。
    static let listRowHorizontalInset: CGFloat = 8

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

/// 面板背景：深色用深色渐变；浅色默认纯白背景，
/// 开启玻璃特效后使用系统原生玻璃（macOS 26+ Liquid Glass，
/// macOS 14–25 经典 AppKit 菜单磨砂）。
struct TMPanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let glassEnabled: Bool

    var body: some View {
        if colorScheme == .dark {
            TM.panelBackground
        } else if glassEnabled {
            if #available(macOS 26.0, *) {
                LiquidGlassBackground()
            } else {
                NativeGlassBackground()
            }
        } else {
            Color.white
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



/// 所有页面共用的面板表面。页面只提供内容；窗口提案、边距、背景、测量与缩放在此统一。
struct PanelSurface<Content: View>: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelNavigationState.self) private var navigation
    let onPanelSizeChange: (PanelSize) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                content()
            }
            .padding(.horizontal, TM.panelHorizontal)
            .padding(.vertical, PanelLayoutMetrics.rootVerticalChrome / 2)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .onPreferenceChange(PanelHeightPreferenceKey.self) { height in
            guard let height else { return }
            navigation.reportMeasuredHeight(height)
        }
        .background(TMPanelBackground(glassEnabled: store.settings.glassEffectEnabled))
        .overlay {
            PanelWindowAppearanceBridge(appearanceMode: store.settings.appearanceMode)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            PanelHeightResizeHandle(
                panelHeight: CGFloat(navigation.displayedSize.height),
                onChanged: { navigation.setUserHeight($0, persist: false) },
                onEnded: { navigation.setUserHeight($0, persist: true) }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .onChange(of: navigation.displayedSize, initial: true) { _, size in
            onPanelSizeChange(size)
        }
        .ignoresSafeArea()
    }
}

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(PanelNavigationState.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onPanelSizeChange: (PanelSize) -> Void
    let onReorderModeChange: (Bool) -> Void
    /// 面板只剩概览一页：设置、添加订阅与编辑订阅都发生在独立设置窗口里，
    /// 面板只负责把这三件事说出去。
    let onOpenSettings: () -> Void
    let onAddSubscription: () -> Void
    let onEditSubscription: (UUID) -> Void
    @State private var confirmQuit = false
    @State private var isReordering = false
    @State private var subscriptionRowHeights: [UUID: CGFloat] = [:]
    /// Debug 的状态预览（TM-06）由状态栏右键菜单触发，所以状态放在导航状态里而不是视图的
    /// `@State`：菜单是控制器建的，它够不到视图内部的状态。
    #if DEBUG
    var previewMode: StatusPreviewMode?
    #endif

    init(
        onPanelSizeChange: @escaping (PanelSize) -> Void = { _ in },
        onReorderModeChange: @escaping (Bool) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        onAddSubscription: @escaping () -> Void = {},
        onEditSubscription: @escaping (UUID) -> Void = { _ in }
    ) {
        self.onPanelSizeChange = onPanelSizeChange
        self.onReorderModeChange = onReorderModeChange
        self.onOpenSettings = onOpenSettings
        self.onAddSubscription = onAddSubscription
        self.onEditSubscription = onEditSubscription
    }

    var body: some View {
        PanelSurface(onPanelSizeChange: onPanelSizeChange) {
            dashboardContent
        }
        .foregroundStyle(TM.textPrimary)
        #if DEBUG
        .overlay {
            if let previewMode = navigation.previewMode {
                StatusPreviewOverlay(mode: previewMode) {
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { navigation.previewMode = nil }
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
        .modifier(TMColorSchemeModifier(mode: store.settings.appearanceMode))
        .onChange(of: store.settings.autoRefreshEnabled) { _, enabled in
            if enabled { store.start() } else { store.stop() }
        }
    }

    private var dashboardContent: some View {
        return VStack(alignment: .leading, spacing: 0) {
            DashboardHeader(
                status: synchronizationStatus,
                isRefreshing: store.isRefreshing,
                onAdd: onAddSubscription,
                onRefresh: { store.refreshAll(source: .manual) },
                onSettings: onOpenSettings,
                onQuit: { confirmQuit = true },
                isReordering: isReordering,
                onToggleReorder: store.subscriptions.count > 1 ? { toggleReordering() } : nil
            )
            // 6 + 列表的 2pt 顶部内边距 = 根容器的 8pt 顶部内边距，让图标上下留白对称。
            .padding(.bottom, 6)

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
            if store.subscriptions.isEmpty {
                MenuBarEmptyState { onAddSubscription() }
                    .frame(
                        maxHeight: navigation.hasManualHeight ? .infinity : nil,
                        alignment: .top
                    )
            } else {
                if isReordering {
                    reorderHint
                        .padding(.bottom, 8)
                }
                subscriptionList
            }
        }
        .onChange(of: store.subscriptions.map(\.id)) { _, ids in
            let currentIDs = Set(ids)
            guard subscriptionRowHeights.keys.contains(where: { !currentIDs.contains($0) }) else { return }
            subscriptionRowHeights = subscriptionRowHeights.filter { currentIDs.contains($0.key) }
        }
        .onChange(of: isReordering) { _, value in onReorderModeChange(value) }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.15), value: isReordering)
        .reportsIntrinsicPanelHeight(chrome: PanelLayoutMetrics.rootVerticalChrome)
        .onDisappear { isReordering = false }
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
        guard !store.subscriptions.isEmpty else { return 0 }
        var contentHeight: CGFloat = 0
        for subscription in store.subscriptions {
            guard let height = subscriptionRowHeights[subscription.id], height > 0, height.isFinite else {
                return PanelLayoutMetrics.subscriptionListMaxHeight
            }
            contentHeight += height
        }
        contentHeight += CGFloat(store.subscriptions.count - 1) * 8
        return min(contentHeight, PanelLayoutMetrics.subscriptionListMaxHeight)
    }

    private var subscriptionList: some View {
        let move: ((IndexSet, Int) -> Void)? = isReordering
            ? { source, destination in
                // 落位默认是硬切：List 的 onMove 只在外面套一层动画时才会让
                // 卡片滑到新位置；沿用面板既有的 easeOut 0.2s 语言。
                withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) {
                    store.moveSubscriptions(fromOffsets: source, toOffset: destination)
                }
            }
            : nil

        return List {
            ForEach(store.subscriptions) { subscription in
                subscriptionRow(for: subscription)
            }
            .onMove(perform: move)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.all, 0, for: .scrollContent)
        .padding(.horizontal, -TM.listRowHorizontalInset)
        .frame(
            idealHeight: subscriptionListIdealHeight,
            // 面板被屏幕限高时列表按剩余空间收缩，超出部分在列表内部滚动；
            // 否则列表按内容高度铺开，让面板高度继续随内容自适应。
            maxHeight: navigation.hasManualHeight || navigation.isHeightLimitedByScreen
                ? .infinity
                : subscriptionListIdealHeight
        )
        .padding(.vertical, 2)
    }

    private func recordRowHeights(_ measured: [UUID: CGFloat]) {        for (id, height) in measured {
            guard height > 0, height.isFinite,
                  subscriptionRowHeights[id] != height,
                  store.subscriptions.contains(where: { $0.id == id }) else { continue }
            subscriptionRowHeights[id] = height
        }
    }

    private func subscriptionRow(for subscription: Subscription) -> some View {
        subscriptionCard(for: subscription)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SubscriptionRowHeightsPreferenceKey.self,
                        value: [subscription.id: geometry.size.height]
                    )
                }
            }
            .padding(.bottom, subscription.id == store.subscriptions.last?.id ? 0 : 8)
            .onPreferenceChange(SubscriptionRowHeightsPreferenceKey.self) { recordRowHeights($0) }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }

    private func subscriptionCard(for subscription: Subscription) -> some View {
        SubscriptionRowCard(
            store: store,
            subscription: subscription,
            onEdit: { onEditSubscription(subscription.id) },
            isReordering: isReordering
        )
    }

    private func toggleReordering() {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) { isReordering.toggle() }
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
}/// 概览列表的单行卡片。快照在这一层读取，而不是在 `MenuBarView` 的 body 里：
/// 读在父视图上时，任何一次快照写入都会让整个面板失效（列表理想高度重算、`List` 与表头
/// 一起重建，还会带出一次行高测量 → 改 frame 的布局级联）；读在这里则只失效这一行。
/// 注意观测粒度是 `snapshots` 这个属性本身，不是其中的单个键：别的订阅更新时本行
/// body 仍会重算，但父视图与其余行的布局不再被牵动。
/// 非 private：`SnapshotObservationTests` 直接引用它来锁定读取位置。
struct SubscriptionRowCard: View {
    let store: UsageStore
    let subscription: Subscription
    let onEdit: () -> Void
    let isReordering: Bool

    var body: some View {
        SubscriptionMenuCard(
            subscription: subscription,
            snapshot: store.snapshots[subscription.id],
            onEdit: onEdit,
            isReordering: isReordering
        )
    }
}

/// 供应商选择正文：一列供应商卡片。
///
/// 只在独立设置窗口里用（「添加订阅…」那一页）：面板的二级页已经全部搬到窗口里了，
/// 所以这里不再需要「有没有上一页」「要不要上报面板高度」这类宿主旋钮。
struct ProviderSelectionContent: View {
    let onSelect: (ProviderID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("选择供应商")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.5)
                Text("选择要连接的 AI 服务")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ProviderRegistry.all, id: \.id) { definition in
                        ProviderSelectionCard(definition: definition) { onSelect(definition.id) }
                    }
                }
                .padding(.vertical, 8)
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
    /// 同步状态由时间驱动，单独用 TimelineView 包裹，避免整块面板随计时器重建。
    let status: (Date) -> (text: String, color: Color)
    let isRefreshing: Bool
    let onAdd: () -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    var isReordering: Bool = false
    var onToggleReorder: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let sync = status(context.date)
                HStack(spacing: 5) {
                    Circle()
                        .fill(sync.color)
                        .frame(width: 6, height: 6)
                    Text(sync.text)
                        .foregroundStyle(TM.textTertiary)
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityElement(children: .combine)
            }
            .layoutPriority(1)

            Spacer()

            // 仅用 accent 图标色区分“添加订阅”，静止不加底色，悬停反馈交给 HeaderIconButton。
            HeaderIconButton(systemName: "plus", label: "添加订阅", tint: TM.accent, action: onAdd)

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

            if let onToggleReorder {
                HeaderIconButton(
                    systemName: isReordering ? "checkmark" : "line.3.horizontal",
                    label: isReordering ? "完成排序" : "排序",
                    isActive: isReordering,
                    action: onToggleReorder
                )
            }

            HeaderIconButton(systemName: "gearshape", label: "设置", action: onSettings)
            HeaderIconButton(systemName: "power", label: "退出 TokenMeter", tint: .red, action: onQuit)
        }
    }
}

/// 20pt 见方的图标按钮：悬停加一层 accent 半透明填充与边框（点击范围不变），rotation 用于刷新旋转反馈。
struct HeaderIconButton: View {
    let systemName: String
    let label: String
    var rotation: Double = 0
    var isActive: Bool = false
    /// 可选固定前景色（如退出按钮的红色）；为 nil 时沿用激活/悬停派生色。
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    /// hover 背景的显示条件：悬停且可用；禁用时不显示悬停反馈。
    static func showsHoverFeedback(hovering: Bool, isEnabled: Bool) -> Bool { hovering && isEnabled }

    private var showsHoverBackground: Bool {
        Self.showsHoverFeedback(hovering: hovering, isEnabled: isEnabled)
    }

    /// 悬停填充与描边用 accent 的低透明度派生色，比普通卡片填充更显眼又能透出底下的玻璃。
    private var hoverFill: Color { TM.accent.opacity(0.18) }
    private var hoverBorder: Color { TM.accent.opacity(0.45) }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(tint ?? (isActive ? TM.accent : (showsHoverBackground ? TM.textPrimary : TM.textSecondary)))
                .frame(width: 20, height: 20)
                .background(
                    showsHoverBackground ? hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(showsHoverBackground ? hoverBorder : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
