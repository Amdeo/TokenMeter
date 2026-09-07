import SwiftUI

// 订阅用量数据的共享展示组件：菜单栏面板的紧凑卡片行。
// 视觉统一为深色卡片 + 细描边 + 平台色点缀；不使用大面积渐变或发光。
struct SubscriptionUsageView: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot

    @ViewBuilder
    var body: some View {
        switch subscription.platform {
        case .deepSeek:
            BalanceMenuRow(quota: snapshot.quotas.first { $0.kind == .balance })
        case .kimi:
            VStack(alignment: .leading, spacing: 8) {
                if SubscriptionCardPresentation.showsKimiTotalUsageBody(overallUsageRatio: snapshot.overallUsageRatio) {
                    TotalUsageMenuRow(
                        ratio: snapshot.overallUsageRatio,
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
        default:
            if snapshot.quotas.isEmpty {
                Text("暂无可显示的额度数据")
                    .font(.system(size: 11))
                    .foregroundStyle(TM.textSecondary)
            } else {
                // OpenCodeGo 头部锚点已显示「每月窗口」，正文不再重复该配额行。
                let monthly = subscription.platform == .openCodeGo
                    ? snapshot.quotas.first { $0.name.contains("月") }
                    : nil
                let rows = snapshot.quotas.filter { $0.id != monthly?.id }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { quota in
                        QuotaProgressRow(
                            title: quota.name,
                            quota: quota,
                            tint: SubscriptionQuotaColors.resolve(subscription.quotaColors, quota: quota)
                        )
                    }
                }
            }
        }
    }
}

extension UsageSnapshot {
    func visibleStatus(for subscription: Subscription) -> QuotaStatus {
        switch subscription.platform {
        case .deepSeek:
            return status(for: [.balance])
        case .kimi:
            let coreKinds: Set<Quota.Kind> = [.fiveHour, .weekly]
            return quotas.contains { coreKinds.contains($0.kind) }
                ? status(for: coreKinds)
                : status(for: [.balance])
        default:
            // realtime 状态的可见额度只按配额派生，避免上游附带的 errorMessage
            // 把通用平台（zhipu/openCodeGo/miniMax）覆盖成错误状态。
            return status(for: Set(Quota.Kind.allCases))
        }
    }
}

// MARK: - 卡片数值锚点（呈现辅助）

/// 订阅卡片顶部「单一数值锚点」的统一呈现逻辑：
/// 统一比例阈值、可注入 now 的重置文案，以及按平台/快照派生的锚点。
struct SubscriptionCardPresentation {
    struct Anchor {
        let label: String
        let value: String
        let status: QuotaStatus
        let accessibilityLabel: String
        let color: Color
    }

    /// 用量比例 → 状态色：统一 绿 <80% / 橙 ≥80% / 红 =100% 的语义。
    static func ratioStatus(for ratio: Double) -> QuotaStatus {
        if ratio >= 1 { return .exhausted }
        if ratio >= 0.8 { return .warning }
        return .normal
    }

    /// 把重置时间转成用户可读的「X 小时后刷新额度」文案；now 供测试注入。
    static func resetHintText(for resetAt: Date, now: Date = .now) -> String {
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "即将刷新额度" }
        if seconds < 3600 {
            return "\(max(1, Int(seconds / 60))) 分钟后刷新额度"
        }
        if seconds < 86400 {
            return "\(max(1, Int(seconds / 3600))) 小时后刷新额度"
        }
        return "\(max(1, Int(seconds / 86400))) 天后刷新额度"
    }

    static func anchor(subscription: Subscription, snapshot: UsageSnapshot) -> Anchor? {
        switch subscription.platform {
        case .deepSeek:
            return nil
        case .kimi:
            guard subscription.authMethod != .manualAPIKey else { return nil }
            if let ratio = snapshot.overallUsageRatio {
                let percent = ratio.formatted(.percent.precision(.fractionLength(1)))
                let status = ratioStatus(for: ratio)
                let color = SubscriptionQuotaColors.hasOverallConfiguration(subscription.quotaColors)
                    ? SubscriptionQuotaColors.resolveOverall(subscription.quotaColors)
                    : status.tint
                return Anchor(
                    label: "总使用量",
                    value: percent,
                    status: status,
                    accessibilityLabel: "总使用量 \(percent)",
                    color: color
                )
            }
            if let quota = snapshot.quotas.first(where: { $0.kind == .fiveHour || $0.kind == .weekly }) {
                return quotaAnchor(quota, colors: subscription.quotaColors)
            }
            return nil
        default:
            // 通用平台：优先取「每月」窗口作为锚点（更有信息量的周期值），
            // 没有每月窗口再回退到第一个配额。
            let monthly = snapshot.quotas.first { $0.name.contains("月") }
            guard let quota = monthly ?? snapshot.quotas.first else { return nil }
            return quotaAnchor(quota, colors: subscription.quotaColors)
        }
    }

    /// 卡片整体的无障碍朗读文案：按快照状态派生状态文案，仅在 realtime 追加额度状态与锚点数值。
    static func cardAccessibilityLabel(
        subscription: Subscription,
        snapshot: UsageSnapshot?,
        anchor: Anchor?
    ) -> String {
        var parts: [String] = ["编辑 \(subscription.name) 的配置"]
        guard let snapshot else {
            parts.append("等待首次刷新…")
            return parts.joined(separator: "，")
        }

        switch snapshot.state {
        case .notConfigured:
            parts.append("需要配置")
        case .authenticationRequired:
            parts.append("认证已失效")
        case .unsupported:
            parts.append("暂不支持额度接口")
        case .error:
            parts.append("获取失败")
        case .realtime:
            parts.append(snapshot.visibleStatus(for: subscription).label)
            if let anchor {
                parts.append(anchor.accessibilityLabel)
            }
        }

        return parts.joined(separator: "，")
    }

    /// Kimi 卡片体是否需要渲染「总使用量」行：头部锚点已显示总使用量
    /// （overallUsageRatio 存在）时返回 false，避免头部与 body 重复；
    /// 比例缺失时返回 true，保留原有行（该行在 ratio 为 nil 时渲染为空）。
    static func showsKimiTotalUsageBody(overallUsageRatio: Double?) -> Bool {
        overallUsageRatio == nil
    }

    /// 卡片体是否渲染实时用量：以快照状态而非 errorMessage 判断，
    /// 避免 realtime+message 落入 stateRow 的 EmptyView，或 notConfigured+nil 误显示用量。
    static func showsRealtimeUsageBody(for snapshot: UsageSnapshot) -> Bool {
        snapshot.state == .realtime
    }

    /// 卡片头部状态点颜色：按快照状态派生，避免 notConfigured/unsupported
    /// 携带的错误消息把状态点覆盖成红色；仅 realtime 继续沿用额度状态语义。
    static func cardIndicatorStatus(snapshot: UsageSnapshot, subscription: Subscription) -> QuotaStatus {
        switch snapshot.state {
        case .authenticationRequired, .notConfigured, .unsupported:
            return .warning
        case .error:
            return .error
        case .realtime:
            return snapshot.visibleStatus(for: subscription)
        }
    }

    private static func quotaAnchor(_ quota: Quota, colors: [String: UInt32]) -> Anchor {
        let percent = quota.fraction.formatted(.percent.precision(.fractionLength(0)))
        let color = SubscriptionQuotaColors.hasConfiguration(colors, name: quota.name, kind: quota.kind)
            ? SubscriptionQuotaColors.resolve(colors, quota: quota)
            : quota.status.tint
        return Anchor(
            label: quota.name,
            value: percent,
            status: quota.status,
            accessibilityLabel: "\(quota.name)，已用 \(percent)",
            color: color
        )
    }
}

// MARK: - 基础图形

/// 细轨道计量条；单色填充，状态变化时平滑过渡，减少动态效果时保持静态。
private struct MeterBar: View {
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

// MARK: - 紧凑行（菜单栏面板）

private struct TotalUsageMenuRow: View {
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

private struct BalanceMenuRow: View {
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

private struct QuotaProgressRow: View {
    let title: String
    let quota: Quota?
    let tint: Color

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
                    Text(quota.fraction, format: .percent.precision(.fractionLength(1)))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .layoutPriority(1)
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
                HStack {
                    Text(quota.status == .normal ? "正常" : quota.status.label)
                        .foregroundStyle(quota.status == .normal ? TM.textTertiary : quota.status.tint)
                    Spacer()
                    Text(quota.resetAt.map { SubscriptionCardPresentation.resetHintText(for: $0) } ?? "")
                        .foregroundStyle(TM.textTertiary)
                }
                .font(.system(size: 9))
                .accessibilityHidden(quota.resetAt == nil)
            } else {
                Text("接口未返回")
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textTertiary)
            }
        }
    }
}

extension Platform {
    var tint: Color {
        switch self {
        case .deepSeek: .blue
        case .zhipu: .purple
        case .kimi: .indigo
        case .openCodeGo: .green
        case .miniMax: .orange
        }
    }
}

extension QuotaStatus {
    var tint: Color {
        switch self {
        case .normal: TM.ok
        case .warning: TM.warn
        case .exhausted, .error: TM.danger
        }
    }
}
