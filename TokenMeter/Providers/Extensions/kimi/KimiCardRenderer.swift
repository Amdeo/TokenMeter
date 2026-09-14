import SwiftUI

/// Kimi 订阅卡：月额度 / 5 小时 / 每周三行窗口。月额度行与顶部「总使用量」
/// 锚点同源（订阅月额度），锚点给出大字数值，正文行补进度条与重置时间。
struct KimiCardRenderer: ProviderCardRenderer {
    /// 订阅制的三个窗口额度；其余（如加油包余额、月消费）不进入正文。
    private static let windowKinds: Set<Quota.Kind> = [.monthly, .fiveHour, .weekly]

    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        let windowQuotas = snapshot.quotas.filter { Self.windowKinds.contains($0.kind) }
        if !windowQuotas.isEmpty {
            // 顺序由解析层的 quotaRank 决定：月额度 → 5 小时 → 每周。
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(windowQuotas) { quota in
                        QuotaProgressRow(
                            title: quota.name,
                            quota: quota,
                            tint: SubscriptionQuotaColors.resolve(subscription.quotaColors, quota: quota)
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
                    BalanceMenuRow(quota: quota, title: quota.name)
                }
            }
        )
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        // 仅订阅制（非 API Key）模式显示总使用量锚点。
        guard subscription.authMethodID != .apiKey else { return nil }
        if let ratio = snapshot.overallUsageRatio {
            let percent = ratio.formatted(.percent.precision(.fractionLength(1)))
            let status = SubscriptionCardPresentation.ratioStatus(for: ratio)
            let color = SubscriptionQuotaColors.hasOverallConfiguration(subscription.quotaColors)
                ? SubscriptionQuotaColors.resolveOverall(subscription.quotaColors)
                : status.tint
            return CardSummary(
                label: "总使用量",
                value: percent,
                accessibilityLabel: "总使用量 \(percent)",
                colorRGB: color.tokenMeterRGB
            )
        }
        if let quota = snapshot.quotas.first(where: { $0.kind == .fiveHour || $0.kind == .weekly }) {
            return .usage(quota, subscription: subscription)
        }
        return nil
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        // 月额度也计入状态：月额度见底时不应再显示「正常」。
        let kinds = Self.windowKinds
        return snapshot.quotas.contains { kinds.contains($0.kind) }
            ? snapshot.status(for: kinds)
            : snapshot.status(for: [.balance])
    }
}
