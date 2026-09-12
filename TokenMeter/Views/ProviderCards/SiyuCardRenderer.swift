import SwiftUI

/// Siyu API 卡片：顶部摘要显示可用余额，正文按订阅分组展示
/// 每日/每周/每月 三个额度窗口（已用 / 总量 + 重置提示 + 到期日）。
/// 额度名称由 provider 生成，形如 "DeepSeek大月卡 · 每日"，
/// 本渲染器按 " · " 切分还原订阅段落。
/// 复用标准基础行组件（BalanceMenuRow / QuotaProgressRow）。
struct SiyuCardRenderer: ProviderCardRenderer {
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        let groups = Self.planGroups(snapshot.quotas.filter { $0.kind == .generic })
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                if groups.isEmpty {
                    Text("暂无活动订阅")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(group.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(TM.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    if let expiresAt = group.expiresAt {
                                        Text(QuotaProgressRow.expiryHintText(for: expiresAt))
                                            .font(.system(size: 9))
                                            .foregroundStyle(TM.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(group.windows) { quota in
                                        QuotaProgressRow(
                                            title: Self.windowTitle(from: quota.name),
                                            quota: quota,
                                            tint: SubscriptionQuotaColors.resolve(subscription.quotaColors, quota: quota),
                                            valueOverride: Self.amountText(quota),
                                            hideResetHint: false,
                                            hideExpiryHint: true
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        )
    }

    /// 把 provider 命名形如 "DeepSeek大月卡 · 每日" 的额度行按订阅名分组。
    static func planGroups(_ quotas: [Quota]) -> [PlanGroup] {
        var order: [String] = []
        var buckets: [String: [Quota]] = [:]
        for quota in quotas {
            let plan = planName(from: quota.name)
            if buckets[plan] == nil { order.append(plan) }
            buckets[plan, default: []].append(quota)
        }
        return order.map { plan in
            let windows = buckets[plan] ?? []
            return PlanGroup(
                name: plan,
                expiresAt: windows.compactMap(\.expiresAt).max(),
                windows: windows
            )
        }
    }

    /// 额度行名称中 " · " 前的订阅名；无分隔符时原样返回。
    static func planName(from quotaName: String) -> String {
        guard let range = quotaName.range(of: " · ") else { return quotaName }
        return String(quotaName[..<range.lowerBound])
    }

    /// 额度行名称中 " · " 后的窗口名（每日/每周/每月）。
    static func windowTitle(from quotaName: String) -> String {
        guard let range = quotaName.range(of: " · ") else { return quotaName }
        return String(quotaName[range.upperBound...])
    }

    /// 订阅段落：订阅名 + 到期日 + 三个额度窗口行。
    struct PlanGroup: Identifiable {
        let name: String
        let expiresAt: Date?
        let windows: [Quota]

        var id: String { name }
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
