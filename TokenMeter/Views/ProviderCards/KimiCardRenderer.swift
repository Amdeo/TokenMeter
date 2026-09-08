import SwiftUI

/// Kimi 订阅卡：5 小时/每周额度行布局。总用量百分比由顶部摘要锚点呈现，
/// 正文不再独占一行（避免与锚点重复）。
struct KimiCardRenderer: ProviderCardRenderer {
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        let coreKinds: Set<Quota.Kind> = [.fiveHour, .weekly]
        let coreQuotas = snapshot.quotas.filter { coreKinds.contains($0.kind) }
        if !coreQuotas.isEmpty {
            // 订阅制：渲染 5 小时 + 每周两行。
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    QuotaProgressRow(
                        title: "5 小时额度",
                        quota: snapshot.quotas.first { $0.kind == .fiveHour },
                        tint: SubscriptionQuotaColors.resolve(
                            subscription.quotaColors, name: "5 小时额度", kind: .fiveHour
                        )
                    )
                    QuotaProgressRow(
                        title: "每周额度",
                        quota: snapshot.quotas.first { $0.kind == .weekly },
                        tint: SubscriptionQuotaColors.resolve(
                            subscription.quotaColors, name: "每周额度", kind: .weekly
                        )
                    )
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
            return Self.quotaSummary(quota, colors: subscription.quotaColors)
        }
        return nil
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        let coreKinds: Set<Quota.Kind> = [.fiveHour, .weekly]
        return snapshot.quotas.contains { coreKinds.contains($0.kind) }
            ? snapshot.status(for: coreKinds)
            : snapshot.status(for: [.balance])
    }

    private static func quotaSummary(_ quota: Quota, colors: [String: UInt32]) -> CardSummary {
        let percent = quota.fraction.formatted(.percent.precision(.fractionLength(0)))
        let color = SubscriptionQuotaColors.hasConfiguration(colors, name: quota.name, kind: quota.kind)
            ? SubscriptionQuotaColors.resolve(colors, quota: quota)
            : quota.status.tint
        return CardSummary(
            label: quota.name,
            value: percent,
            accessibilityLabel: "\(quota.name)，已用 \(percent)",
            colorRGB: color.tokenMeterRGB
        )
    }
}
