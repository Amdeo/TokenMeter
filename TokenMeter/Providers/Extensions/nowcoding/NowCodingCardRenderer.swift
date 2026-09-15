import SwiftUI

/// NowCoding 卡片：顶部摘要显示可用余额，正文显示余额行 +
/// 每个活动订阅的额度进度（用量 / 每日额度 + 下次重置）。
/// 复用标准基础行组件（BalanceMenuRow / QuotaProgressRow）。
struct NowCodingCardRenderer: ProviderCardRenderer {
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        let planRows = snapshot.quotas.filter { $0.kind == .generic }
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                if planRows.isEmpty {
                    Text("暂无活动订阅")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(planRows) { quota in
                            QuotaProgressRow(
                                title: quota.name,
                                quota: quota,
                                tint: SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: quota),
                                valueOverride: Self.amountText(quota),
                                hideResetHint: true
                            )
                        }
                    }
                }
            }
        )
    }

    /// “¥已用 / ¥总量”格式（两位小数）。
    private static func amountText(_ quota: Quota) -> String {
        "¥\(String(format: "%.2f", quota.used / quota.unit.displayScale)) / ¥\(String(format: "%.2f", quota.limit / quota.unit.displayScale))"
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        guard let balance = snapshot.quotas.first(where: { $0.kind == .balance }) else { return nil }
        return .balance(balance, subscription: subscription)
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        snapshot.status(for: Set(Quota.Kind.allCases))
    }
}