import SwiftUI

/// OpenCode Go 卡片：两种样式。
/// - 标准（默认）：通用额度列表——顶部摘要锚点取「每月窗口」，正文列 5 小时 / 每周两行进度条。
/// - 紧凑：图标 + 名称 / 数据两行，三个窗口（5 小时 / 每周 / 每月）挤在数据行，无进度条。
struct OpenCodeGoCardRenderer: ProviderCardRenderer {
    /// 标准样式画进度条；紧凑样式只画数值。额外声明 `.quotaValues`，
    /// 让紧凑样式下额度颜色目标不丢（值仍按订阅配色渲染）。
    var capabilities: SubscriptionCardCapabilities { [.progressMeters, .quotaValues] }

    var supportedStyles: Set<SubscriptionCardStyle> { [.standard, .compact] }

    /// 标准样式的正文 / 摘要 / 状态沿用通用额度列表：锚点优先「每月窗口」这一周期最长的值，
    /// 正文跳过该行，其余窗口按解析顺序画进度条。
    private var list: QuotaListCardRenderer { QuotaListCardRenderer(anchorHint: "月") }

    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        list.makeBody(subscription: subscription, snapshot: snapshot)
    }

    /// 仅在紧凑样式下接管整卡；数据行无内容时退回标准外壳。
    func makeCard(
        definition: any ProviderDefinition,
        subscription: Subscription,
        snapshot: UsageSnapshot
    ) -> AnyView? {
        guard subscription.cardStyle == .compact else { return nil }
        let stats = Self.stats(snapshot: snapshot)
        guard !stats.isEmpty else { return nil }
        return AnyView(CompactUsageCard(definition: definition, subscription: subscription, stats: stats))
    }

    /// 紧凑数据行：接口返回了哪个窗口就放哪一项（5 小时 → 每周 → 每月），
    /// 与标准卡片同一批额度、同一套配色键。
    static func stats(snapshot: UsageSnapshot) -> [CompactUsageStat] {
        OpenCodeGoUsageProvider.UsageWindow.allCases.compactMap { window in
            guard let quota = snapshot.quotas.first(where: { $0.name == window.quotaName }) else { return nil }
            return CompactUsageStat(
                label: window.compactLabel,
                value: CompactUsageStat.percentText(quota.fraction),
                source: .quota(quota),
                status: quota.status,
                resetAt: quota.resetAt
            )
        }
    }

    /// 与真实卡一致：三个用量窗口（标准样式下月窗口由顶部锚点呈现）。
    func sampleSnapshot(subscription: Subscription) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Self.sampleQuota(.rolling, used: 62, resetIn: 4 * 3_600),
            Self.sampleQuota(.weekly, used: 34, resetIn: 2 * 86_400),
            Self.sampleQuota(.monthly, used: 52, resetIn: 9 * 86_400)
        ])
    }

    private static func sampleQuota(
        _ window: OpenCodeGoUsageProvider.UsageWindow,
        used: Double,
        resetIn: TimeInterval
    ) -> Quota {
        Quota(name: window.quotaName, used: used, limit: 100, resetAt: .now.addingTimeInterval(resetIn))
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        list.summary(subscription: subscription, snapshot: snapshot)
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        list.status(subscription: subscription, snapshot: snapshot)
    }
}
