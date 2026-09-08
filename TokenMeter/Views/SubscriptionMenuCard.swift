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

    @State private var hovering = false

    private var providerDefinition: any ProviderDefinition {
        ProviderRegistry.definition(for: subscription.providerID) ?? UnsupportedProviderDefinition(providerID: subscription.providerID)
    }

    @MainActor
    private var authMethodTitle: String {
        providerDefinition.authMethods.first { $0.id == subscription.authMethodID }?.title
            ?? subscription.authMethodID.rawValue
    }

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
                PlatformLogo(definition: providerDefinition, size: 30)
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
