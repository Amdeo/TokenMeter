import SwiftUI

/// Kimi 订阅卡：紧凑双行——图标在左，右侧名称 / 数据两行，两行合计高等于图标高。
/// 数据行把 5 小时 / 每周 / 月（总使用量）挤在同一行，不画进度条、不显示重置时间。
/// 订阅制拿不到窗口时（API Key 形态）数据行退回平台余额。
struct KimiCardRenderer: ProviderCardRenderer {
    /// 紧凑卡不画条，但数值仍按订阅配色渲染（5 小时 / 每周 / 总使用量 / 余额），
    /// 因此声明 `.quotaValues`（额度颜色目标照旧）与 `.balanceValues`（余额目标），
    /// 不声明 `.progressMeters`——卡片确实没有任何进度条。
    var capabilities: SubscriptionCardCapabilities { [.quotaValues, .balanceValues] }

    /// 接管整卡：图标与名称/数据同排，共享外壳的头部不参与。
    func makeCard(
        definition: any ProviderDefinition,
        subscription: Subscription,
        snapshot: UsageSnapshot
    ) -> AnyView? {
        AnyView(KimiCompactCardView(definition: definition, subscription: subscription, snapshot: snapshot))
    }

    /// 订阅制的窗口额度；余额、加油包等不进入状态派生。
    private static let windowKinds: Set<Quota.Kind> = [.fiveHour, .weekly]

    /// 标准外壳下的正文（realtime 以外的状态走共享状态行，不经过这里）：
    /// 正常路径由 `makeCard` 接管整卡，这里返回同一份数据行，避免两处视觉漂移。
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        AnyView(KimiCompactDataLine(subscription: subscription, snapshot: snapshot))
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
