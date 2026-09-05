import SwiftUI
import AppKit

// MARK: - 设计令牌

/// TokenMeter 深色工具视觉的统一设计令牌，参考 UI/index.html 的克制深色面板语言。
enum TM {
    static let panelTop = Color(hex: 0x222324)
    static let panelMid = Color(hex: 0x1A1B1C)
    static let panelBottom = Color(hex: 0x181919)
    static let editorBackground = Color(hex: 0x1A1B1C)

    static let cardFill = Color.white.opacity(0.028)
    static let cardFillHover = Color.white.opacity(0.052)
    static let fieldFill = Color.black.opacity(0.19)
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.14)
    static let divider = Color.white.opacity(0.075)

    static let textPrimary = Color(hex: 0xF4F4F1)
    static let textSecondary = Color(hex: 0x8F9391)
    static let textTertiary = Color(hex: 0x737875)

    static let accent = Color(hex: 0x5BAAFF)
    static let ok = Color(hex: 0x67C89D)
    static let warn = Color(hex: 0xD59B5C)
    static let danger = Color(hex: 0xD97B6C)

    static var panelBackground: LinearGradient {
        LinearGradient(
            colors: [panelTop, panelMid, panelBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

struct PanelVisibilityGate {
    private(set) var isVisible = false

    mutating func didReceiveDisplayEvent() -> Bool {
        guard !isVisible else { return false }
        isVisible = true
        return true
    }

    mutating func didReceiveHiddenEvent() { isVisible = false }
}

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismissMenuBar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    @State private var confirmQuit = false
    #if DEBUG
    @State private var previewMode: StatusPreviewMode?
    #endif

    private func openAddSubscription() {
        dismissMenuBar()
        SubscriptionEditorWindow.show(store: store)
    }

    private func openEditor(for subscription: Subscription) {
        dismissMenuBar()
        SubscriptionEditorWindow.show(store: store, subscription: subscription)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarHeader(
                isRefreshing: store.isRefreshing,
                onRefresh: { Task { await store.refreshAll(source: .manual) } },
                onSettings: {
                    withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) { showingSettings = true }
                }
            )

            if showingSettings {
                SettingsPanel(
                    settings: store.settings,
                    onBack: {
                        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.16)) { showingSettings = false }
                    },
                    onPreview: previewEntryAction
                )
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                dashboardContent
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 398)
        .background(TM.panelBackground)
        .foregroundStyle(TM.textPrimary)
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
        .confirmationDialog("退出 TokenMeter？", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("退出 TokenMeter", role: .destructive) {
                store.stop()
                NSApplication.shared.terminate(nil)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后将停止后台刷新。")
        }
        .overlay(alignment: .top) {
            PanelVisibilityBridge {
                guard store.settings.refreshOnOpen else { return }
                Task { await store.refreshAll(source: .panelOpen) }
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
        .onChange(of: store.settings.autoRefreshEnabled) { _, enabled in
            if enabled { store.start() } else { store.stop() }
        }
    }

    private var dashboardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI 额度")
                    .font(.system(size: 20, weight: .semibold).width(.standard))
                    .tracking(-0.5)
                Text(dashboardMeta)
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            }
            .padding(.top, 12)
            .padding(.bottom, 14)

            if store.orderedSubscriptions.isEmpty {
                MenuBarEmptyState { openAddSubscription() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.orderedSubscriptions) { subscription in
                            SubscriptionMenuCard(
                                subscription: subscription,
                                snapshot: store.snapshots[subscription.id],
                                onEdit: { openEditor(for: subscription) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 460)
            }

            footer
        }
    }

    private var dashboardMeta: String {
        let count = store.orderedSubscriptions.count
        let updated = store.lastRefreshAt.map { " · \($0.tokenMeterTimeText) 更新" } ?? ""
        return "\(count) 个服务\(updated)"
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(TM.divider).frame(height: 1)
                .padding(.top, 12)
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
            .padding(.top, 10)
        }
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

private struct PanelVisibilityBridge: NSViewRepresentable {
    let onVisible: () -> Void

    func makeNSView(context: Context) -> VisibilityNSView {
        let view = VisibilityNSView()
        view.onVisible = onVisible
        return view
    }

    func updateNSView(_ nsView: VisibilityNSView, context: Context) { nsView.onVisible = onVisible }
}

private final class VisibilityNSView: NSView {
    var onVisible: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var gate = PanelVisibilityGate()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        gate.didReceiveHiddenEvent()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, self.gate.didReceiveDisplayEvent() else { return }
            self.onVisible?()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.gate.didReceiveHiddenEvent()
        })
        if window.isKeyWindow, gate.didReceiveDisplayEvent() { onVisible?() }
    }

    deinit {
        MainActor.assumeIsolated {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

private struct MenuBarHeader: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TM.textPrimary)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TM.border, lineWidth: 1))

            Text("TokenMeter")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.2)

            Spacer()

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
private struct HeaderIconButton: View {
    let systemName: String
    let label: String
    var rotation: Double = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(hovering ? TM.textPrimary : TM.textSecondary)
                .frame(width: 32, height: 32)
                .background(hovering ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hovering ? TM.border : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
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
                .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    @State private var hovering = false

    private var status: QuotaStatus? {
        guard let snapshot else { return nil }
        if snapshot.state == .authenticationRequired { return .warning }
        if snapshot.errorMessage != nil { return .error }
        return snapshot.visibleStatus(for: subscription)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PlatformLogo(platform: subscription.platform, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(subscription.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if let status {
                            Circle()
                                .fill(status == .normal ? TM.ok : (status == .warning ? TM.warn : TM.danger))
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(status.label)
                        }
                    }
                    Text("\(subscription.platform.rawValue) · \(subscription.authMethod.label)")
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onEdit) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(hovering ? TM.textPrimary : TM.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(hovering ? 0.08 : 0.045), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("编辑订阅")
                .accessibilityLabel("编辑 \(subscription.name)")
            }

            cardBody
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tmCard(hovering: hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var cardBody: some View {
        if let snapshot, snapshot.errorMessage == nil {
            SubscriptionUsageView(subscription: subscription, snapshot: snapshot, style: .compact)
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
                         title: "认证已失效", detail: "打开编辑窗口重新连接")
        case .notConfigured:
            cardStateRow(icon: "lock.trianglebadge.exclamationmark", tint: TM.warn,
                         title: "需要配置", detail: snapshot.errorMessage ?? "打开编辑窗口完成配置")
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

// MARK: - 设置页

private struct SettingsPanel: View {
    @Bindable var settings: SettingsStore
    let onBack: () -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                Label("返回概览", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TM.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回概览")
            .accessibilityLabel("返回概览")
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.5)
                Text("TokenMeter 偏好设置")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            }
            .padding(.top, 12)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection("通用") {
                    VStack {
                        settingsToggle("登录时启动", isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        ))
                        HStack {
                            Text(settings.loginItemStatus.label)
                            Spacer()
                            Button("刷新状态") { settings.refreshLoginItemStatus() }
                                .buttonStyle(.plain)
                                .foregroundStyle(TM.accent)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                        settingsToggle("打开时刷新", isOn: $settings.refreshOnOpen)
                        settingsToggle("后台自动刷新", isOn: $settings.autoRefreshEnabled, isLast: true)
                    }
                    if let error = settings.loginItemError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TM.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection("通知") {
                        settingsToggle("余额偏低提醒", isOn: $settings.lowBalanceAlerts)
                        settingsToggle("认证过期提醒", isOn: $settings.authenticationAlerts)
                        settingsToggle("服务错误提醒", isOn: $settings.serviceErrorAlerts)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(settings.notificationStatus == .authorized ? TM.ok : TM.warn)
                                    .frame(width: 6, height: 6)
                                Text(settings.notificationStatusLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.textSecondary)
                                Spacer()
                                if settings.notificationStatus == .notDetermined {
                                    Button("允许通知") { settings.requestNotificationsIfNeeded() }
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(TM.accent)
                                        .buttonStyle(.plain)
                                } else if settings.notificationStatus == .denied {
                                    Button("前往系统设置") { settings.openNotificationSettings() }
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(TM.accent)
                                        .buttonStyle(.plain)
                                        .help("打开系统通知设置")
                                }
                            }
                            if settings.notificationStatus == .denied {
                                Text("请在 系统设置 → 通知 → TokenMeter 中开启。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(TM.textTertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }

                    settingsSection("余额阈值") {
                        thresholdRow("CNY", value: $settings.cnyBalanceThreshold)
                        thresholdRow("USD", value: $settings.usdBalanceThreshold, isLast: true)
                    }

                    #if DEBUG
                    settingsSection("开发者") {
                        Button(action: onPreview) {
                            HStack {
                                Text("预览状态")
                                    .font(.system(size: 12))
                                    .foregroundStyle(TM.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(TM.textTertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("预览不同状态（仅 Debug）")
                        .accessibilityLabel("预览状态")
                    }
                    #endif

                    HStack {
                        Label("TokenMeter 私有本地凭证文件 · 受文件权限保护", systemImage: "lock.fill")
                        Spacer()
                        Text("TokenMeter")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textTertiary)
                    .padding(.top, 2)
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 430)
        }
        .onAppear {
            settings.refreshLoginItemStatus()
            settings.updateNotificationStatus()
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(TM.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !isLast {
                Rectangle().fill(TM.divider).frame(height: 1).padding(.leading, 12)
            }
        }
    }

    private func thresholdRow(_ currency: String, value: Binding<Double>, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("低于 \(currency)")
                    .font(.system(size: 12))
                    .foregroundStyle(TM.textPrimary)
                Spacer()
                TextField("0", value: value, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(TM.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: 78)
                    .background(TM.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(TM.border, lineWidth: 1))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            if !isLast {
                Rectangle().fill(TM.divider).frame(height: 1).padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(TM.textTertiary)
            VStack(spacing: 0) { content() }
                .background(TM.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TM.border, lineWidth: 1))
        }
    }
}

// MARK: - Debug 状态预览（仅 Debug 构建，纯本地示例值，不触碰 store/持久层）

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
                                .background(item == current ? Color.white.opacity(0.1) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
