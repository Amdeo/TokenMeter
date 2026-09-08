import SwiftUI

// MARK: - 基础行组件

/// 细轨道计量条；单色填充，状态变化时平滑过渡，减少动态效果时保持静态。
struct MeterBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(TM.meterTrack)
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.35), value: fraction)
    }
}

/// 余额单行展示（无进度条）。
struct BalanceMenuRow: View {
    let quota: Quota?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("可用余额")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TM.textSecondary)
            Spacer(minLength: 8)
            Text(quota?.remainingText ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(quota.map { $0.status == .normal ? TM.textPrimary : $0.status.tint } ?? TM.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 总使用量比例行（如 Kimi 的 overallUsageRatio）。
struct TotalUsageMenuRow: View {
    let ratio: Double?
    let color: Color

    var body: some View {
        if let ratio {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("总使用量")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TM.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(ratio, format: .percent.precision(.fractionLength(1)))
                        .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(color)
                }
                MeterBar(fraction: ratio, tint: color, height: 4)
                    .accessibilityLabel("总使用量已用比例")
                    .accessibilityValue(ratio.formatted(.percent.precision(.fractionLength(1))))
            }
        }
    }
}

/// 通用额度进度行。
struct QuotaProgressRow: View {
    let title: String
    let quota: Quota?
    let tint: Color
    /// 右侧主数值：nil 显示百分比，非 nil（如“剩余 $0.03”）显示金额。
    var valueOverride: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TM.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if let quota {
                    Text(valueOverride ?? quota.fraction.formatted(.percent.precision(.fractionLength(1))))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .layoutPriority(1)
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(TM.textSecondary)
                }
            }
            if let quota {
                MeterBar(fraction: quota.fraction, tint: tint, height: 4)
                    .accessibilityLabel("\(title)已用比例")
                    .accessibilityValue(quota.fraction.formatted(.percent.precision(.fractionLength(1))))
                HStack(spacing: 8) {
                    Text(quota.status == .normal ? "正常" : quota.status.label)
                        .foregroundStyle(quota.status == .normal ? TM.textTertiary : quota.status.tint)
                    Spacer(minLength: 4)
                    if let expiresAt = quota.expiresAt {
                        Text(Self.expiryHintText(for: expiresAt))
                            .foregroundStyle(TM.textTertiary)
                            .lineLimit(1)
                    }
                    if let resetAt = quota.resetAt {
                        Text(SubscriptionCardPresentation.resetHintText(for: resetAt))
                            .foregroundStyle(TM.textTertiary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9))
                .accessibilityHidden(quota.resetAt == nil && quota.expiresAt == nil)
            } else {
                Text("接口未返回")
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textTertiary)
            }
        }
    }

    /// “剩 N 天到期”文案（now 供测试注入）。
    static func expiryHintText(for expiresAt: Date, now: Date = .now) -> String {
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0 else { return "已到期" }
        if seconds < 86400 {
            return "剩 \(max(1, Int(seconds / 3600))) 小时到期"
        }
        return "剩 \(max(1, Int(seconds / 86400))) 天到期"
    }
}

// MARK: - 标准卡片渲染器

/// 余额型供应商：正文显示单行余额，无顶部摘要，状态只看余额。
struct BalanceCardRenderer: ProviderCardRenderer {
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        AnyView(BalanceMenuRow(quota: snapshot.quotas.first { $0.kind == .balance }))
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        nil
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        snapshot.status(for: [.balance])
    }
}

/// 通用额度列表供应商；支持 `anchorHint` 指定顶部摘要优先取某名称的额度
/// （如 OpenCode Go 优先「每月窗口」），正文跳过该额度行。
struct QuotaListCardRenderer: ProviderCardRenderer {
    /// 顶部摘要优先匹配的额度名称子串；nil 时取第一个额度。
    var anchorHint: String? = nil

    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        if snapshot.quotas.isEmpty {
            return AnyView(
                Text("暂无可显示的额度数据")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            )
        }
        let excludedID: UUID?
        if let anchorHint, let quota = snapshot.quotas.first(where: { $0.name.contains(anchorHint) }) {
            excludedID = quota.id
        } else {
            excludedID = nil
        }
        let rows = snapshot.quotas.filter { $0.id != excludedID }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { quota in
                    QuotaProgressRow(
                        title: quota.name,
                        quota: quota,
                        tint: SubscriptionQuotaColors.resolve(subscription.quotaColors, quota: quota)
                    )
                }
            }
        )
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        guard !snapshot.quotas.isEmpty else { return nil }
        let quota: Quota
        if let anchorHint, let matched = snapshot.quotas.first(where: { $0.name.contains(anchorHint) }) {
            quota = matched
        } else {
            quota = snapshot.quotas[0]
        }
        let percent = quota.fraction.formatted(.percent.precision(.fractionLength(0)))
        let color = SubscriptionQuotaColors.hasConfiguration(subscription.quotaColors, name: quota.name, kind: quota.kind)
            ? SubscriptionQuotaColors.resolve(subscription.quotaColors, quota: quota)
            : quota.status.tint
        return CardSummary(
            label: quota.name,
            value: percent,
            accessibilityLabel: "\(quota.name)，已用 \(percent)",
            colorRGB: color.tokenMeterRGB
        )
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        snapshot.status(for: Set(Quota.Kind.allCases))
    }
}

/// 未知/失效供应商的降级卡片。
struct UnsupportedCardRenderer: ProviderCardRenderer {
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        AnyView(
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TM.textSecondary)
                Text("暂不支持该供应商的额度接口")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            }
        )
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        nil
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        .error
    }
}
