import SwiftUI

/// Siyu API 卡片：顶部摘要显示可用余额，正文按订阅分组展示
/// 每日/每周/每月 额度窗口（已用 / 总量 + 重置提示 + 到期日）。
/// 分组用额度行自带的分组元数据（`Quota.group`），不解析显示名。
/// 复用标准基础行组件（BalanceMenuRow / QuotaProgressRow）。
struct SiyuCardRenderer: ProviderCardRenderer {
    var capabilities: SubscriptionCardCapabilities { [.progressMeters, .balanceValues] }

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
                                if let title = group.title {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(title)
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
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(group.windows) { quota in
                                        QuotaProgressRow(
                                            title: Self.rowTitle(quota),
                                            quota: quota,
                                            tint: SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: quota),
                                            valueOverride: Self.amountText(quota),
                                            hideResetHint: false,
                                            // 段落头已展示到期日；没有段落头时留在行内。
                                            hideExpiryHint: group.title != nil
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

    /// 按额度行的分组元数据归组：同键同段，顺序取首次出现的位置。
    /// 缺少分组元数据的行各自成段（不与其他行合并，也不会丢失）。
    static func planGroups(_ quotas: [Quota]) -> [PlanGroup] {
        var order: [String] = []
        var buckets: [String: [Quota]] = [:]
        for quota in quotas {
            let key = quota.group?.key ?? quota.id.uuidString
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(quota)
        }
        return order.map { key in
            let windows = buckets[key] ?? []
            return PlanGroup(
                key: key,
                title: windows.first?.group?.title,
                expiresAt: windows.compactMap(\.expiresAt).max(),
                windows: windows
            )
        }
    }

    /// 行内标题：段落头已显示分组名，行内只留窗口名（"DeepSeek大月卡 · 每日" → "每日"）。
    static func rowTitle(_ quota: Quota) -> String {
        guard let title = quota.group?.title else { return quota.name }
        let prefix = "\(title) · "
        return quota.name.hasPrefix(prefix) ? String(quota.name.dropFirst(prefix.count)) : quota.name
    }

    /// 订阅段落：订阅名 + 到期日 + 该订阅的额度窗口行。
    struct PlanGroup: Identifiable {
        let key: String
        /// 段落标题；缺少分组元数据的行没有标题，只渲染行本身。
        let title: String?
        let expiresAt: Date?
        let windows: [Quota]

        var id: String { key }
    }

    /// “$已用 / $总量”格式（两位小数）。与悬浮条详情卡片共用同一套紧凑写法
    /// （`Quota.compactText`），两处显示的是同一个数，就不该有两套币种写法。
    private static func amountText(_ quota: Quota) -> String {
        let used = Quota.compactText(value: quota.used, unit: quota.unit)
        let limit = Quota.compactText(value: quota.limit, unit: quota.unit)
        return "\(used) / \(limit)"
    }

    /// 与真实 Siyu 卡一致：一个带分组元数据的套餐（每日/每月窗口 + 到期日）+ 余额行
    /// （余额供顶部 summary 锚点使用）。
    func sampleSnapshot(subscription: Subscription) -> UsageSnapshot {
        let plan = Quota.Group(key: "plan", title: "DeepSeek 大月卡")
        let daily = Quota(
            name: "DeepSeek 大月卡 · 每日", used: 4.2, limit: 10,
            resetAt: .now.addingTimeInterval(3600), expiresAt: .now.addingTimeInterval(86400 * 12),
            unit: .currency(code: "CNY", scale: 1), kind: .generic, group: plan
        )
        let monthly = Quota(
            name: "DeepSeek 大月卡 · 每月", used: 86.5, limit: 300,
            resetAt: .now.addingTimeInterval(86400 * 9), expiresAt: .now.addingTimeInterval(86400 * 12),
            unit: .currency(code: "CNY", scale: 1), kind: .generic, group: plan
        )
        let balance = Quota(
            name: "可用余额", used: 12.34, limit: 100, resetAt: nil,
            unit: .currency(code: "CNY", scale: 1), kind: .balance
        )
        return .realtime(subscription: subscription, quotas: [daily, monthly, balance])
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        guard let balance = snapshot.quotas.first(where: { $0.kind == .balance }) else { return nil }
        return .balance(balance, subscription: subscription)
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        snapshot.status(for: Set(Quota.Kind.allCases))
    }
}
