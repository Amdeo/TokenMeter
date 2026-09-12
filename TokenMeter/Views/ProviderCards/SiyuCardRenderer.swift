import SwiftUI

/// Siyu API 卡片：顶部摘要显示可用余额，正文显示每个有效订阅的
/// 月额度进度（已用 / 总量 + 到期日）。
/// 复用标准基础行组件（BalanceMenuRow / QuotaProgressRow）。
struct SiyuCardRenderer: ProviderCardRenderer {
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
                                tint: SubscriptionQuotaColors.resolve(subscription.quotaColors, quota: quota),
                                valueOverride: Self.amountText(quota),
                                hideResetHint: true
                            )
                        }
                    }
                }
            }
        )
    }

    /// “$已用 / $总量”格式（两位小数），货币符号按单位代码映射。
    private static func amountText(_ quota: Quota) -> String {
        let symbol = currencySymbol(for: quota.unit.label)
        let used = String(format: "%.2f", quota.used / quota.unit.displayScale)
        let limit = String(format: "%.2f", quota.limit / quota.unit.displayScale)
        return "\(symbol)\(used) / \(symbol)\(limit)"
    }

    private static func currencySymbol(for code: String?) -> String {
        switch code {
        case "USD": "$"
        case "CNY": "¥"
        case "EUR": "€"
        case "JPY": "¥"
        case "GBP": "£"
        default: "\(code ?? "") "
        }
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        guard let balance = snapshot.quotas.first(where: { $0.kind == .balance }) else { return nil }
        let color = SubscriptionQuotaColors.hasConfiguration(subscription.quotaColors, name: balance.name, kind: balance.kind)
            ? SubscriptionQuotaColors.resolve(subscription.quotaColors, quota: balance)
            : balance.status.tint
        return CardSummary(
            label: "余额",
            value: balance.remainingText,
            accessibilityLabel: "可用余额 \(balance.remainingText)",
            colorRGB: color.tokenMeterRGB
        )
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        snapshot.status(for: Set(Quota.Kind.allCases))
    }
}
