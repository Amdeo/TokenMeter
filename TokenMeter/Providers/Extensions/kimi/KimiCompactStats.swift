import Foundation

// MARK: - Kimi 紧凑卡数据行

/// Kimi 紧凑卡（共享的 `CompactUsageCard`）的数据行内容：5 小时 → 每周 → 月（总使用量）；
/// 订阅制拿不到窗口时（API Key 形态）退回余额行。
enum KimiCompactStats {
    static func stats(snapshot: UsageSnapshot) -> [CompactUsageStat] {
        var stats: [CompactUsageStat] = []
        for (kind, label) in [(Quota.Kind.fiveHour, "5h"), (.weekly, "周")] {
            guard let quota = snapshot.quotas.first(where: { $0.kind == kind }) else { continue }
            stats.append(
                CompactUsageStat(
                    label: label,
                    value: CompactUsageStat.percentText(quota.fraction),
                    source: .quota(quota),
                    status: quota.status,
                    resetAt: quota.resetAt
                )
            )
        }
        if let ratio = snapshot.overallUsageRatio {
            stats.append(
                CompactUsageStat(
                    label: "月",
                    value: CompactUsageStat.percentText(ratio),
                    source: .overall,
                    status: SubscriptionCardPresentation.ratioStatus(for: ratio),
                    resetAt: snapshot.overallResetAt
                )
            )
        }
        if stats.isEmpty, let balance = snapshot.quotas.first(where: { $0.kind == .balance }) {
            stats.append(
                CompactUsageStat(
                    label: "余额",
                    value: balance.remainingText,
                    source: .quota(balance),
                    status: balance.status,
                    resetAt: nil
                )
            )
        }
        return stats
    }
}
