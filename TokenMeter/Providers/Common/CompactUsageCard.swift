import SwiftUI

// MARK: - 紧凑样式（共享呈现）

/// 紧凑样式（`SubscriptionCardStyle.compact`）的整卡呈现：图标在左，右侧上下两行
/// （名称 / 数据），两行合计高度等于图标高度；不画进度条。
///
/// 数据行由供应商 renderer 组装成 `[CompactUsageStat]`：共享层只管布局、字号、
/// 长按倒计时与配色解析，不猜任何供应商的窗口含义，也不在这里按供应商分支。
///
/// 经 `ProviderCardRenderer.makeCard` 接管整卡，因此图标与名称不再由共享外壳绘制。
struct CompactUsageCard: View {
    let definition: any ProviderDefinition
    let subscription: Subscription
    let stats: [CompactUsageStat]

    /// 图标尺寸，也是两行文本块的高度：两行加起来正好等于它。
    static let iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            PlatformLogo(definition: definition, size: Self.iconSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(subscription.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                CompactUsageStatLine(subscription: subscription, stats: stats)
            }
            .frame(height: Self.iconSize)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 单值紧凑样式（余额）

/// 余额卡的紧凑样式：单行——图标 + 名称 + 金额。
///
/// 余额只有一个数值，没有需要并排的窗口，所以不套 `CompactUsageCard` 的两行布局；
/// 金额贴右且字号比两行卡的数据行大，一眼就能读到。金额自带币种（「CNY 28.17」），
/// 因此不再重复「可用余额」这类标签。
struct CompactBalanceCard: View {
    let definition: any ProviderDefinition
    let subscription: Subscription
    let quota: Quota

    /// 图标尺寸：与两行紧凑卡一致，卡片高度因此不变（图标 30 + 上下各 11pt 内边距）。
    static let iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 9) {
            PlatformLogo(definition: definition, size: Self.iconSize)
            Text(subscription.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(quota.remainingText)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BalanceMenuRow.valueColor(quota: quota, colors: subscription.currentQuotaColors))
                .lineLimit(1)
                // 名称过长时先截断名称，金额始终完整可见。
                .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 数据行

/// 一行数字：`5h 62%  周 34%  月 52%`（标签 10pt 次要色 + 数值 12pt 半粗等宽）。
/// 标签与数值都由供应商 renderer 给出，这里只负责排版。
struct CompactUsageStatLine: View {
    let subscription: Subscription
    let stats: [CompactUsageStat]

    /// 各项数值的间距：常态与长按态一致——长按换成倒计时时各项位置不移动。
    static let statSpacing: CGFloat = 14
    /// 数值槽位最小宽度：按最长倒计时（"4h59m" ≈ 42pt）预留，常态百分比同样按它占位。
    /// 余额等更长的值只会撑开自己（且没有右侧邻居），不影响其它项。
    static let statValueMinWidth: CGFloat = 44

    @Environment(\.tokenMeterShowsResetCountdown) private var showsResetCountdown

    var body: some View {
        HStack(spacing: Self.statSpacing) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                HStack(spacing: 3) {
                    Text(stat.label)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                    Text(stat.displayValue(showsResetCountdown: showsResetCountdown))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(color(for: stat))
                        .frame(minWidth: Self.statValueMinWidth, alignment: .leading)
                }
            }
        }
        .lineLimit(1)
    }

    /// 数值颜色：额度行（窗口或余额）走订阅的按额度配色，总使用量走 overall 配色——
    /// 与标准卡片同一套解析，用户在颜色设置里配过的颜色在这里同样生效。
    @MainActor
    private func color(for stat: CompactUsageStat) -> Color {
        switch stat.source {
        case let .quota(quota):
            if quota.kind == .balance {
                return BalanceMenuRow.valueColor(quota: quota, colors: subscription.currentQuotaColors)
            }
            return SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: quota)
        case .overall:
            if SubscriptionQuotaColors.hasOverallConfiguration(subscription.currentQuotaColors) {
                return SubscriptionQuotaColors.resolveOverall(subscription.currentQuotaColors)
            }
            return stat.status == .normal ? TM.textPrimary : stat.status.tint
        }
    }
}

// MARK: - 数据行内容（纯数据，便于测试）

/// 紧凑卡数据行的一项：小标签 + 数值 + 配色来源。
/// 供应商 renderer 决定放哪几项（如窗口百分比、余额金额、总使用量比例）。
struct CompactUsageStat {
    enum Source {
        /// 额度行（窗口或余额）：配色走订阅的按额度配置。
        case quota(Quota)
        /// 总使用量聚合（顶部锚点那份数据）：配色走订阅的 overall 配置。
        case overall
    }

    let label: String
    let value: String
    let source: Source
    let status: QuotaStatus
    /// 该数值对应的重置时间；余额等没有重置概念时为 nil。
    let resetAt: Date?

    /// 长按态展示值：有重置时间就换倒计时（d/h/m），否则保持原值（如余额金额）——不改常态 `value`。
    func displayValue(showsResetCountdown: Bool, now: Date = .now) -> String {
        guard showsResetCountdown, let resetAt else { return value }
        return SubscriptionCardPresentation.resetCountdownText(for: resetAt, now: now)
    }

    /// 紧凑行放不下小数位：百分比取整（标准卡片行内是 1 位小数）。
    static func percentText(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)))
    }
}
