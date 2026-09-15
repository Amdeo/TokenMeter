import SwiftUI

// MARK: - 紧凑双行卡（Kimi）

/// Kimi 紧凑双行卡：图标在左，右侧上下两行（名称 / 数据），两行合计高度等于图标高度。
/// 数据行把 5 小时、每周、月（总使用量）挤在同一行，不画进度条、不显示重置时间。
///
/// 通过 `ProviderCardRenderer.makeCard` 接管整卡，因此图标与名称不再由共享外壳绘制；
/// 字号比标准卡片小一档（名称 12 / 数值 12 / 标签 10），配色与阈值复用共享 helper。
struct KimiCompactCardView: View {
    let definition: any ProviderDefinition
    let subscription: Subscription
    let snapshot: UsageSnapshot

    /// 图标尺寸，也是两行文本块的高度：两行加起来正好等于它。
    static let iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            PlatformLogo(definition: definition, size: Self.iconSize)
            VStack(alignment: .leading, spacing: 0) {
                nameLine
                Spacer(minLength: 0)
                KimiCompactDataLine(subscription: subscription, snapshot: snapshot)
            }
            .frame(height: Self.iconSize)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var nameLine: some View {
        HStack(spacing: 5) {
            Text(subscription.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Circle()
                .fill(indicatorStatus.tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }

    @MainActor
    private var indicatorStatus: QuotaStatus {
        SubscriptionCardPresentation.cardIndicatorStatus(snapshot: snapshot, subscription: subscription)
    }
}

// MARK: - 数据行

/// 一行数字：`5h 62%  周 34%  月 52%`（标签 10pt 次要色 + 数值 12pt 半粗等宽）。
/// 订阅制拿不到窗口时（API Key 形态）退回余额。紧凑卡的第二行与标准外壳下的正文共用它。
struct KimiCompactDataLine: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                HStack(spacing: 3) {
                    Text(stat.label)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                    Text(stat.value)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(color(for: stat))
                }
            }
        }
        .lineLimit(1)
    }

    private var stats: [KimiCompactStat] {
        KimiCompactStat.stats(snapshot: snapshot)
    }

    /// 数值颜色：窗口/余额走订阅的按额度配色，月（总使用量）走 overall 配色——
    /// 与标准卡片同一套解析，用户在颜色设置里配过的颜色在这里同样生效。
    @MainActor
    private func color(for stat: KimiCompactStat) -> Color {
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
struct KimiCompactStat {
    enum Source {
        /// 额度行（窗口或余额）：配色走订阅的按额度配置。
        case quota(Quota)
        /// 月（总使用量聚合）：配色走订阅的 overall 配置。
        case overall
    }

    let label: String
    let value: String
    let source: Source
    let status: QuotaStatus

    /// 数据行内容：5 小时 → 每周 → 月（总使用量）；
    /// 订阅制拿不到窗口时（API Key 形态）退回余额行。
    static func stats(snapshot: UsageSnapshot) -> [KimiCompactStat] {
        var stats: [KimiCompactStat] = []
        for (kind, label) in [(Quota.Kind.fiveHour, "5h"), (.weekly, "周")] {
            guard let quota = snapshot.quotas.first(where: { $0.kind == kind }) else { continue }
            stats.append(
                KimiCompactStat(
                    label: label,
                    value: percentText(quota.fraction),
                    source: .quota(quota),
                    status: quota.status
                )
            )
        }
        if let ratio = snapshot.overallUsageRatio {
            stats.append(
                KimiCompactStat(
                    label: "月",
                    value: percentText(ratio),
                    source: .overall,
                    status: SubscriptionCardPresentation.ratioStatus(for: ratio)
                )
            )
        }
        if stats.isEmpty, let balance = snapshot.quotas.first(where: { $0.kind == .balance }) {
            stats.append(
                KimiCompactStat(
                    label: "余额",
                    value: balance.remainingText,
                    source: .quota(balance),
                    status: balance.status
                )
            )
        }
        return stats
    }

    /// 紧凑行放不下小数位：百分比取整（标准卡片行内是 1 位小数）。
    private static func percentText(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)))
    }
}
