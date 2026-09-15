import SwiftUI

// MARK: - 空状态

struct MenuBarEmptyState: View {
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

struct SubscriptionMenuCard: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot?
    let onEdit: () -> Void
    var isReordering: Bool = false

    /// 长按判定阈值：按住超过它才切到重置倒计时；短于此仍是单击跳转。
    /// 计时由 `pressCountdownTask` 控制：卡片上同时挂着单击手势时，SwiftUI 的手势仲裁会把
    /// `onLongPressGesture` 的识别推迟到 ~0.75s，调小它的阈值也没有用（实测 0.1/0.4/0.5 都是 0.75s）。
    static let resetCountdownLongPressDuration: Duration = .milliseconds(500)
    /// 只用来取按压起止回调的 `onLongPressGesture` 阈值：设得足够大，让它自身的识别永不触发。
    static let resetCountdownPressTrackingDuration: TimeInterval = 60
    /// 长按允许的最大位移：超过即判为拖动（滚动/排序），取消长按。
    static let resetCountdownLongPressDistance: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 长按态：为真时卡片正文显示额度重置倒计时。
    @State private var showsResetCountdown = false
    /// 本次按压是否已触过长按；抬手时的单击动作据此不跳转。
    @State private var didLongPress = false
    /// 本次按压的 0.5s 计时；抬手或取消时作废。
    @State private var pressCountdownTask: Task<Void, Never>?
    @State private var hovering = false

    private var providerDefinition: any ProviderDefinition {
        ProviderRegistry.definition(for: subscription.providerID) ?? UnsupportedProviderDefinition(providerID: subscription.providerID)
    }

    @MainActor
    private var authMethodTitle: String {
        providerDefinition.authMethods.first { $0.id == subscription.authMethodID }?.title
            ?? subscription.authMethodID.rawValue
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
        // 排序模式使用非 Button 容器，让原生 List 接管拖放；普通模式单击编辑、长按切换倒计时。
        // macOS 上 Button 会吞掉 `onLongPressGesture`，因此这里用 tap + long press 手势自己组合同一次按压。
        Group {
            if isReordering {
                cardContent
            } else {
                cardContent
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleTap)
                    .onLongPressGesture(
                        minimumDuration: Self.resetCountdownPressTrackingDuration,
                        maximumDistance: Self.resetCountdownLongPressDistance,
                        perform: {},
                        onPressingChanged: handlePressingChange
                    )
                    // 位移超过阈值即视为拖动（滚动/排序/轮播翻页），取消长按计时。
                    // `onPressingChanged` 只在抬手时才报取消，因此位移要自己盯。
                    .simultaneousGesture(
                        DragGesture(minimumDistance: Self.resetCountdownLongPressDistance)
                            .onChanged { _ in cancelPressCountdown() }
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { handleTap() }
            }
        }
        .environment(\.tokenMeterShowsResetCountdown, showsResetCountdown)
        .tmCard(hovering: hovering)
        .onHover { hovering in
            self.hovering = hovering
            if !hovering {
                cancelPressCountdown()
                endResetCountdown()
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(isReordering ? "拖动排序" : "单击编辑配置 · 长按查看额度重置时间")
        .accessibilityLabel(accessibilityLabel)
    }

    /// 单击才跳转；长按结束后抬手不跳转。
    private func handleTap() {
        guard !didLongPress else { return }
        onEdit()
    }

    /// 按住达到阈值：切到重置倒计时视图。
    private func beginResetCountdown() {
        didLongPress = true
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { showsResetCountdown = true }
    }

    /// 按压状态回调：`true` 为新一次按下（起表并清掉上一轮的长按标记），`false` 为抬起/取消（停表并还原）。
    private func handlePressingChange(_ pressing: Bool) {
        cancelPressCountdown()
        if pressing {
            didLongPress = false
            pressCountdownTask = Task {
                try? await Task.sleep(for: Self.resetCountdownLongPressDuration)
                guard !Task.isCancelled else { return }
                beginResetCountdown()
            }
            return
        }
        endResetCountdown()
    }

    /// 作废未到时的长按计时（抬手、指针离开、拖动取消都走这里）。
    private func cancelPressCountdown() {
        pressCountdownTask?.cancel()
        pressCountdownTask = nil
    }

    /// 还原长按态（抬起或指针离开卡片）。**不动 `didLongPress`**：它由下一次按下时才清除，
    /// 这样同属一次 mouseUp 的单击回调无论先于还是晚于本回调，都能被 `handleTap` 拦下。
    private func endResetCountdown() {
        guard showsResetCountdown else { return }
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { showsResetCountdown = false }
    }

    private var cardContent: some View {
        Group {
            // 供应商接管整卡时（图标与名称/数据同排这类布局）跳掉标准外壳的头部，
            // 但点击编辑、悬停、内边距与排序手柄仍由本视图负责。
            if let snapshot, snapshot.state == .realtime, let custom = customCard(snapshot: snapshot) {
                HStack(spacing: 8) {
                    custom
                    if isReordering { reorderHandle }
                }
            } else {
                standardContent
            }
        }
        .padding(.horizontal, TM.cardContentHorizontal)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 标准外壳：图标 + 名称/副标题 + 摘要锚点，下面是 renderer 的正文。
    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                PlatformLogo(definition: providerDefinition, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subscription.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(providerDefinition.metadata.displayName) · \(authMethodTitle)")
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
                            .foregroundStyle(Color(hex: anchor.colorRGB))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    .layoutPriority(1)
                }

                if isReordering { reorderHandle }
            }

            cardBody
        }
    }

    /// 供应商整卡渲染；nil 时走标准外壳。
    @MainActor
    private func customCard(snapshot: UsageSnapshot) -> AnyView? {
        providerDefinition.cardRenderer.makeCard(
            definition: providerDefinition,
            subscription: subscription,
            snapshot: snapshot
        )
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(TM.textTertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var cardBody: some View {
        if let snapshot, snapshot.state == .realtime {
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
enum StatusPreviewMode: String, CaseIterable, Identifiable {
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

struct StatusPreviewOverlay: View {
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

    private static let deepSeek = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
    private static let kimi = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiDeviceOAuth)

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
            providerID: .kimi,
            quotas: [],
            updatedAt: .now,
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
