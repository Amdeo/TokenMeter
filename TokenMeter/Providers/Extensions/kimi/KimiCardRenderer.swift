import SwiftUI

/// Kimi 订阅卡：5 小时 / 每周两行窗口。月总额度由顶部「总使用量」锚点呈现，
/// 锚点文案直接带上月额度的重置时间，正文不重复该行。
struct KimiCardRenderer: ProviderCardRenderer {
    var capabilities: SubscriptionCardCapabilities { [.progressMeters, .balanceValues] }

    /// 订阅制的窗口额度；余额、加油包等不进入正文。
    private static let windowKinds: Set<Quota.Kind> = [.fiveHour, .weekly]

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

    /// 与真实 Kimi 卡一致：两个窗口行 + 顶部「总使用量」锚点（含月额度重置时间）。
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
