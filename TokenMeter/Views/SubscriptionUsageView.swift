import SwiftUI

// 订阅用量数据的共享展示组件：菜单栏面板的紧凑卡片行。
// 视觉统一为深色卡片 + 细描边 + 平台色点缀；不使用大面积渐变或发光。
// 正文渲染委托给 ProviderRegistry 中该供应商定义的 cardRenderer，不再按供应商 switch。

struct SubscriptionUsageView: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot

    var body: some View {
        renderer.makeBody(subscription: subscription, snapshot: snapshot)
    }

    @MainActor
    private var renderer: any ProviderCardRenderer {
        ProviderRegistry.definition(for: subscription.providerID)?.cardRenderer ?? UnsupportedCardRenderer()
    }
}

extension UsageSnapshot {
    /// realtime 状态下按供应商 renderer 派生可见额度状态。
    @MainActor
    func visibleStatus(for subscription: Subscription) -> QuotaStatus {
        ProviderRegistry.definition(for: subscription.providerID)?.cardRenderer.status(subscription: subscription, snapshot: self)
            ?? status(for: Set(Quota.Kind.allCases))
    }
}

// MARK: - 卡片数值锚点（呈现辅助）

/// 订阅卡片顶部「单一数值锚点」的统一呈现逻辑：
/// 统一比例阈值、可注入 now 的重置文案，以及按供应商 renderer 派生的摘要。
struct SubscriptionCardPresentation {
    typealias Anchor = CardSummary

    /// 用量比例 → 状态色：统一 绿 <80% / 橙 ≥80% / 红 =100% 的语义。
    static func ratioStatus(for ratio: Double) -> QuotaStatus {
        if ratio >= 1 { return .exhausted }
        if ratio >= 0.8 { return .warning }
        return .normal
    }

    /// 把重置时间转成用户可读的「X 小时后刷新额度」文案；now 供测试注入，
    /// `suffix` 供聚合额度（如 Kimi 总使用量）换成「重置」等措辞。
    static func resetHintText(for resetAt: Date, now: Date = .now, suffix: String = "刷新额度") -> String {
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "即将\(suffix)" }
        if seconds < 3600 {
            return "\(max(1, Int(seconds / 60))) 分钟后\(suffix)"
        }
        if seconds < 86400 {
            return "\(max(1, Int(seconds / 3600))) 小时后\(suffix)"
        }
        return "\(max(1, Int(seconds / 86400))) 天后\(suffix)"
    }

    /// 顶部摘要委托给供应商 renderer。
    @MainActor
    static func anchor(subscription: Subscription, snapshot: UsageSnapshot) -> Anchor? {
        ProviderRegistry.definition(for: subscription.providerID)?.cardRenderer.summary(subscription: subscription, snapshot: snapshot)
    }

    /// 卡片整体的无障碍朗读文案：按快照状态派生状态文案，仅在 realtime 追加额度状态与锚点数值。
    @MainActor
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

    /// 卡片头部状态点颜色：按快照状态派生，避免 notConfigured/unsupported
    /// 携带的错误消息把状态点覆盖成红色；仅 realtime 继续沿用额度状态语义。
    @MainActor
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

// MARK: - 卡片顶部摘要

extension CardSummary {
    /// 用量百分比摘要（顶部锚点）：数值默认即「已用」，标签不再重复；颜色沿配置解析链回退到状态色。
    /// `showsResetHint` 供重置时间拿不到正文行的卡片使用（该额度行已被锚点从正文排除）。
    @MainActor
    static func usage(_ quota: Quota, subscription: Subscription, showsResetHint: Bool = false) -> CardSummary {
        let percent = quota.fraction.formatted(.percent.precision(.fractionLength(0)))
        let resetHint = showsResetHint
            ? quota.resetAt.map { SubscriptionCardPresentation.resetHintText(for: $0, suffix: "重置") }
            : nil
        return CardSummary(
            label: resetHint.map { "\(quota.name) · \($0)" } ?? quota.name,
            value: percent,
            accessibilityLabel: resetHint.map { "\(quota.name)，已用 \(percent)，\($0)" } ?? "\(quota.name)，已用 \(percent)",
            colorRGB: anchorColor(for: quota, subscription: subscription)
        )
    }

    /// 余额摘要：数值用剩余金额，颜色解析规则与用量摘要一致。
    @MainActor
    static func balance(_ quota: Quota, subscription: Subscription) -> CardSummary {
        CardSummary(
            label: "余额",
            value: quota.remainingText,
            accessibilityLabel: "可用余额 \(quota.remainingText)",
            colorRGB: anchorColor(for: quota, subscription: subscription)
        )
    }

    /// 有用户配置时用配置色，否则回退额度状态色。
    @MainActor
    private static func anchorColor(for quota: Quota, subscription: Subscription) -> UInt32 {
        let color = SubscriptionQuotaColors.hasConfiguration(subscription.currentQuotaColors, name: quota.name, kind: quota.kind)
            ? SubscriptionQuotaColors.resolve(subscription.currentQuotaColors, quota: quota)
            : quota.status.tint
        return color.tokenMeterRGB
    }
}
