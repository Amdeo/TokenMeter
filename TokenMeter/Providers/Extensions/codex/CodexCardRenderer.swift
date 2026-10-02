import SwiftUI

/// Moonshot AI Codex 卡片：顶部摘要显示套餐名（拿不到时退回首行额度名），正文按
/// 「账号级窗口 → 按模型限额 → 预付费额度」列出额度行。
///
/// 参考 Pulse 的 `CodexUsageService` 解析出的数据形态（账号级窗口 + 按模型限额 + credits），
/// 落到 TokenMeter 的既有读法：窗口画进度行，余额画单行金额（与中转站同一条规矩）。
/// 套餐名来自 `snapshot.providerData["plan"]`——额度行本身不重复套餐，留一个地方说。
struct CodexCardRenderer: ProviderCardRenderer {
    var capabilities: SubscriptionCardCapabilities { [.progressMeters, .balanceValues] }

    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        let windows = snapshot.quotas.filter { $0.kind != .balance }
        let balances = snapshot.quotas.filter { $0.kind == .balance }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(windows) { quota in
                    QuotaProgressRow(
                        title: quota.name,
                        quota: quota,
                        tint: SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: quota)
                    )
                }
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

    /// 摘要：套餐名（拿不到就用首行额度名）当标签，数值取最接近用尽的那个窗口的已用百分比。
    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        let windows = snapshot.quotas.filter { $0.kind != .balance }
        guard let worst = windows.max(by: { $0.fraction < $1.fraction }) else { return nil }
        let percent = worst.fraction.formatted(.percent.precision(.fractionLength(0)))
        let plan = Self.planName(from: snapshot)
        let status = SubscriptionCardPresentation.ratioStatus(for: worst.fraction)
        // 配过色就用配置色，否则用状态色：与卡片里的进度行、别的供应商的锚点同一条解析链。
        let color = SubscriptionQuotaColors.hasConfiguration(subscription.currentQuotaColors, name: worst.name, kind: worst.kind)
            ? SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: worst)
            : status.tint
        return CardSummary(
            label: plan ?? worst.name,
            value: percent,
            accessibilityLabel: plan.map { "\($0) 套餐，\(worst.name) 已用 \(percent)" } ?? "\(worst.name) 已用 \(percent)",
            colorRGB: color.tokenMeterRGB
        )
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        snapshot.status(for: Set(Quota.Kind.allCases))
    }

    /// 与真实卡一致：账号级两个窗口 + 一条预付费额度（余额行），带套餐名。
    func sampleSnapshot(subscription: Subscription) -> UsageSnapshot {
        .realtime(
            subscription: subscription,
            quotas: [
                Quota(name: "5 小时额度", used: 62, limit: 100, resetAt: .now.addingTimeInterval(7200), kind: .fiveHour),
                Quota(name: "7 天额度", used: 34, limit: 100, resetAt: .now.addingTimeInterval(86_400 * 2), kind: .weekly),
                Quota(name: "可用额度", used: 0, limit: 12.34, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)
            ],
            providerData: .object(["plan": .string("pro")])
        )
    }

    /// 套餐标识 → 用户认得的名字；认不出的原样透传（与解析层同一张表）。
    static func planName(from snapshot: UsageSnapshot) -> String? {
        guard let raw = snapshot.providerData?.string(for: ["plan"]) else { return nil }
        return CodexUsageProvider.planName(raw)
    }
}
