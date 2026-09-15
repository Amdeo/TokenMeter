import SwiftUI

/// Kimi 订阅卡：两种样式。
/// - 标准（默认）：5 小时 / 每周两行进度行，月总额度由顶部「总使用量」锚点呈现（锚点带重置时间）。
/// - 紧凑：图标 + 名称 / 数据两行（两行合计高等于图标高），5 小时 / 每周 / 月挤在数据行，无进度条。
struct KimiCardRenderer: ProviderCardRenderer {
    /// 标准样式画进度条；紧凑样式只画数值。额外声明 `.quotaValues`，
    /// 让紧凑样式下额度颜色目标不丢（值仍按订阅配色渲染）。
    var capabilities: SubscriptionCardCapabilities { [.progressMeters, .quotaValues, .balanceValues] }

    /// 两种样式都实现了：标准走共享外壳，紧凑由 `makeCard` 接管整卡。
    var supportedStyles: Set<SubscriptionCardStyle> { [.standard, .compact] }

    /// 仅在紧凑样式下接管整卡（图标与名称/数据同排，共享外壳的头部不参与）。
    /// 数据行没有内容时（既无窗口也无余额）退回标准外壳，避免只剩图标与名称的空卡。
    func makeCard(
        definition: any ProviderDefinition,
        subscription: Subscription,
        snapshot: UsageSnapshot
    ) -> AnyView? {
        guard subscription.cardStyle == .compact else { return nil }
        let stats = KimiCompactStats.stats(snapshot: snapshot)
        guard !stats.isEmpty else { return nil }
        return AnyView(CompactUsageCard(definition: definition, subscription: subscription, stats: stats))
    }

    /// 订阅制的窗口额度；余额、加油包等不进入正文。
    private static let windowKinds: Set<Quota.Kind> = [.fiveHour, .weekly]

    /// 标准样式的正文：两个窗口进度行；没有窗口时（API Key 形态）退回平台余额行。
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        let windowQuotas = snapshot.quotas.filter { Self.windowKinds.contains($0.kind) }
        if !windowQuotas.isEmpty {
            // 顺序由解析层的 quotaRank 决定：5 小时 → 每周。
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(windowQuotas) { quota in
                        QuotaProgressRow(
                            title: quota.name,
                            quota: quota,
                            tint: SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: quota)
                        )
                    }
                }
            )
        }
        // API Key 回退余额：coding 接口 401/403/404 时回退到平台余额，
        // 渲染余额行而不是“接口未返回”。
        let balances = snapshot.quotas.filter { $0.kind == .balance }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(balances) { quota in
                    BalanceMenuRow(
                        quota: quota,
                        title: quota.name,
                        colors: subscription.currentQuotaColors
                    )
                }
            }
        )
    }

    /// 与真实 Kimi 卡一致：两个窗口 + 月（总使用量）聚合。
    func sampleSnapshot(subscription: Subscription) -> UsageSnapshot {
        .realtime(
            subscription: subscription,
            quotas: [
                Quota(name: "5 小时额度", used: 62, limit: 100, resetAt: .now.addingTimeInterval(7200), kind: .fiveHour),
                Quota(name: "每周额度", used: 34, limit: 100, resetAt: .now.addingTimeInterval(86400 * 2), kind: .weekly)
            ],
            overallUsageRatio: 0.52,
            overallResetAt: .now.addingTimeInterval(86400 * 5)
        )
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        // 仅订阅制（非 API Key）模式显示总使用量锚点。
        guard subscription.authMethodID != .apiKey else { return nil }
        if let ratio = snapshot.overallUsageRatio {
            let percent = ratio.formatted(.percent.precision(.fractionLength(1)))
            // 月额度的重置时间接在「总使用量」后面，如「总使用量 · 5 天后重置」。
            let resetHint = snapshot.overallResetAt.map {
                SubscriptionCardPresentation.resetHintText(for: $0, suffix: "重置")
            }
            let status = SubscriptionCardPresentation.ratioStatus(for: ratio)
            let color = SubscriptionQuotaColors.hasOverallConfiguration(subscription.currentQuotaColors)
                ? SubscriptionQuotaColors.resolveOverall(subscription.currentQuotaColors)
                : status.tint
            return CardSummary(
                label: resetHint.map { "总使用量 · \($0)" } ?? "总使用量",
                value: percent,
                accessibilityLabel: resetHint.map { "总使用量 \(percent)，\($0)" } ?? "总使用量 \(percent)",
                colorRGB: color.tokenMeterRGB
            )
        }
        if let quota = snapshot.quotas.first(where: { $0.kind == .fiveHour || $0.kind == .weekly }) {
            return .usage(quota, subscription: subscription)
        }
        return nil
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        let kinds = Self.windowKinds
        return snapshot.quotas.contains { kinds.contains($0.kind) }
            ? snapshot.status(for: kinds)
            : snapshot.status(for: [.balance])
    }
}
