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
    var title: String = "可用余额"
    /// 当前样式的配色；配过色时优先用配置色（含偏低/用尽状态）。
    var colors: [String: UInt32] = [:]

    /// 余额数值颜色：配过色（name → kind.balance → generic）始终优先，
    /// 否则正常态用文字主色、偏低/用尽维持状态警示色。
    static func valueColor(quota: Quota?, colors: [String: UInt32]) -> Color {
        guard let quota else { return TM.textSecondary }
        if SubscriptionQuotaColors.hasConfiguration(colors, name: quota.name, kind: quota.kind) {
            return SubscriptionQuotaColors.resolve(colors, quota: quota)
        }
        return quota.status == .normal ? TM.textPrimary : quota.status.tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TM.textSecondary)
            Spacer(minLength: 8)
            Text(quota?.remainingText ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Self.valueColor(quota: quota, colors: colors))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 通用额度进度行。
struct QuotaProgressRow: View {
    let title: String
    let quota: Quota?
    let tint: Color
    /// 右侧主数值：nil 显示百分比，非 nil（如“剩余 $0.03”）显示金额。
    var valueOverride: String? = nil
    /// 隐藏每日重置提示（如订阅型额度已带到期日，避免两行时间信息重复）。
    var hideResetHint: Bool = false
    /// 隐藏到期提示（如订阅段落头已单独展示到期日，避免每个窗口行重复）。
    var hideExpiryHint: Bool = false

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
                    Text(valueOverride ?? "已用 \(quota.fraction.formatted(.percent.precision(.fractionLength(1))))")
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
                    if let expiresAt = quota.expiresAt, !hideExpiryHint {
                        Text(Self.expiryHintText(for: expiresAt))
                            .foregroundStyle(TM.textTertiary)
                            .lineLimit(1)
                    }
                    if let resetAt = quota.resetAt, !hideResetHint {
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
/// 余额没有进度条，因此不声明 `.progressMeters`；但余额数值本身可配颜色，
/// 编辑流程据此提供余额颜色设置。
struct BalanceCardRenderer: ProviderCardRenderer {
    var capabilities: SubscriptionCardCapabilities { [.balanceValues] }

    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView {
        AnyView(BalanceMenuRow(
            quota: snapshot.quotas.first { $0.kind == .balance },
            colors: subscription.currentQuotaColors
        ))
    }

    func sampleSnapshot(subscription: Subscription) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(name: "API 余额", used: 81.58, limit: 100, resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance)
        ])
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
                        tint: SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: quota)
                    )
                }
            }
        )
    }

    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary? {
        guard !snapshot.quotas.isEmpty else { return nil }
        if let anchorHint, let matched = snapshot.quotas.first(where: { $0.name.contains(anchorHint) }) {
            // 该额度行已从正文排除，重置时间只能由锚点体现；无 anchorHint 时行内自带提示，避免重复。
            return .usage(matched, subscription: subscription, showsResetHint: true)
        }
        return .usage(snapshot.quotas[0], subscription: subscription)
    }

    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus {
        snapshot.status(for: Set(Quota.Kind.allCases))
    }
}

/// 未知/失效供应商的降级卡片。
struct UnsupportedCardRenderer: ProviderCardRenderer {
    var capabilities: SubscriptionCardCapabilities { [] }

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
