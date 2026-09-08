import SwiftUI

/// Kimi 订阅卡：总使用量锚点 + 5 小时/每周额度行的特殊布局。
struct KimiCardRenderer: ProviderCardRenderer {
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                if let ratio = snapshot.overallUsageRatio {
                    TotalUsageMenuRow(
                        ratio: ratio,
                        color: SubscriptionQuotaColors.resolveOverall(subscription.quotaColors)
                    )
                }
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
