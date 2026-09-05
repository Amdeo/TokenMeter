import SwiftUI

// 订阅用量数据的共享展示组件：菜单栏面板（.compact）与订阅编辑窗口（.full）复用同一套渲染逻辑。
// 视觉统一为深色卡片 + 细描边 + 平台色点缀；不使用大面积渐变或发光。
struct SubscriptionUsageView: View {
    enum Style {
        case compact
        case full
    }

    let subscription: Subscription
    let snapshot: UsageSnapshot
    let style: Style

    @ViewBuilder
    var body: some View {
        switch subscription.platform {
        case .deepSeek:
            if style == .compact {
                BalanceMenuRow(quota: snapshot.quotas.first { $0.kind == .balance })
            } else {
                BalanceHeroCard(
                    quota: snapshot.quotas.first { $0.kind == .balance },
                    tint: subscription.platform.tint
                )
            }
        case .kimi:
            if style == .compact {
                VStack(alignment: .leading, spacing: 10) {
                    TotalUsageMenuRow(ratio: snapshot.overallUsageRatio)
                    QuotaProgressRow(title: "5 小时额度", quota: snapshot.quotas.first { $0.kind == .fiveHour }, tint: .blue)
                    QuotaProgressRow(title: "每周额度", quota: snapshot.quotas.first { $0.kind == .weekly }, tint: .green)
                }
            } else {
                KimiDetailUsageView(snapshot: snapshot)
            }
        default:
            if style == .compact {
                if snapshot.quotas.isEmpty {
                    Text("暂无可显示的额度数据")
                        .font(.system(size: 11))
                        .foregroundStyle(TM.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.quotas) { quota in
                            QuotaProgressRow(title: quota.name, quota: quota)
                        }
                    }
                }
            } else {
                GenericDetailUsageView(quotas: snapshot.quotas)
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
            return overallStatus
        }
    }
}

// 用量比例 → 状态色：统一 绿 <80% / 橙 ≥80% / 红 =100% 的语义。
private func levelStatus(for ratio: Double) -> QuotaStatus {
    if ratio >= 1 { return .exhausted }
    if ratio >= 0.8 { return .warning }
    return .normal
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
                Capsule().fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.35), value: fraction)
    }
}

/// 环形用量仪表：编辑窗口 hero 视觉焦点。
private struct UsageRing: View {
    let ratio: Double
    let tint: Color
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(ratio, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 9)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(ratio, format: .percent.precision(.fractionLength(1)))
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(TM.textPrimary)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.4), value: ratio)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("总使用量已用比例")
        .accessibilityValue(ratio.formatted(.percent.precision(.fractionLength(1))))
    }
}

// MARK: - 紧凑行（菜单栏面板）

private struct TotalUsageMenuRow: View {
    let ratio: Double?

    var body: some View {
        if let ratio {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("总使用量")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TM.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(ratio, format: .percent.precision(.fractionLength(1)))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(levelStatus(for: ratio) == .normal ? TM.textPrimary : levelStatus(for: ratio).tint)
                }
                MeterBar(fraction: ratio, tint: .indigo)
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
            VStack(alignment: .leading, spacing: 3) {
                Text("可用余额")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(TM.textTertiary)
                Text(quota?.remainingText ?? "—")
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .tracking(-0.8)
                    .foregroundStyle(quota.map { $0.status == .normal ? TM.textPrimary : $0.status.tint } ?? TM.textSecondary)
            }
            Spacer()
            if let quota, quota.status != .normal {
                StatusBadge(status: quota.status)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuotaProgressRow: View {
    let title: String
    let quota: Quota?
    var tint: Color? = nil

    private var resolvedTint: Color { tint ?? quota?.status.tint ?? .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TM.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let quota {
                    Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(quota.status == .normal ? TM.textPrimary : resolvedTint)
                } else {
                    Text("—")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(TM.textSecondary)
                }
            }
            if let quota {
                MeterBar(fraction: quota.fraction, tint: resolvedTint, height: 5)
                    .accessibilityLabel("\(title)已用比例")
                    .accessibilityValue(quota.fraction.formatted(.percent.precision(.fractionLength(0))))
                HStack {
                    Text(quota.status == .normal ? "正常" : quota.status.label)
                        .foregroundStyle(quota.status == .normal ? TM.textTertiary : quota.status.tint)
                    Spacer()
                    Text(quota.resetAt.map(resetHintText) ?? "")
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

/// 把重置时间转成用户可读的「X 小时后刷新额度」文案。
private func resetHintText(for resetAt: Date) -> String {
    let seconds = resetAt.timeIntervalSinceNow
    guard seconds > 0 else { return "即将刷新额度" }
    if seconds < 3600 {
        return "\(max(1, Int(seconds / 60))) 分钟后刷新额度"
    }
    if seconds < 86400 {
        return "\(max(1, Int(seconds / 3600))) 小时后刷新额度"
    }
    return "\(max(1, Int(seconds / 86400))) 天后刷新额度"
}

// MARK: - 完整展示（编辑窗口）

private struct KimiDetailUsageView: View {
    let snapshot: UsageSnapshot

    private var coreKinds: Set<Quota.Kind> { [.fiveHour, .weekly] }
    private var hasCoreQuota: Bool { snapshot.quotas.contains { coreKinds.contains($0.kind) } }
    private func quota(_ kind: Quota.Kind) -> Quota? { snapshot.quotas.first { $0.kind == kind } }

    @ViewBuilder
    var body: some View {
        if !hasCoreQuota, let balance = quota(.balance) {
            BalanceHeroCard(
                quota: balance,
                tint: .orange,
                eyebrow: "余额模式",
                note: "当前使用 Moonshot 余额接口，Coding 额度暂不可用"
            )
        } else {
            VStack(spacing: 12) {
                if let ratio = snapshot.overallUsageRatio {
                    TotalUsageHero(ratio: ratio)
                    HStack(alignment: .top, spacing: 10) {
                        QuotaTile(title: "5 小时额度", quota: quota(.fiveHour), tint: .blue)
                        QuotaTile(title: "每周额度", quota: quota(.weekly), tint: .green)
                    }
                } else if let weekly = quota(.weekly) {
                    QuotaTile(title: "每周额度", quota: weekly, tint: .green, hero: true)
                    QuotaTile(title: "5 小时额度", quota: quota(.fiveHour), tint: .blue)
                }
            }
        }
    }
}

/// 总使用量 hero 卡：环形仪表 + 状态徽章，编辑窗口的视觉焦点。
private struct TotalUsageHero: View {
    let ratio: Double

    var body: some View {
        let status = levelStatus(for: ratio)
        HStack(spacing: 18) {
            UsageRing(ratio: ratio, tint: .indigo)
            VStack(alignment: .leading, spacing: 7) {
                Text("总使用量")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TM.textPrimary)
                StatusBadge(status: status)
                Text("来自 Kimi 网页订阅统计")
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tmCard()
    }
}

/// 配额瓷砖卡：大数字 + 计量条 + 刷新时间，两张并排构成 bento 布局；
/// hero 变体用于每周额度升为主卡的场景。
private struct QuotaTile: View {
    let title: String
    let quota: Quota?
    var tint: Color? = nil
    var hero: Bool = false

    private var resolvedTint: Color { tint ?? quota?.status.tint ?? .gray }
    private var padding: CGFloat { hero ? 18 : 14 }
    private var numberSize: CGFloat { hero ? 32 : 24 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(hero ? .system(size: 14, weight: .semibold) : .system(size: 12, weight: .medium))
                    .foregroundStyle(TM.textPrimary)
                if hero, let quota, quota.status != .normal {
                    StatusBadge(status: quota.status)
                }
            }
            if let quota {
                Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: numberSize, weight: .bold, design: .rounded).monospacedDigit())
                    .tracking(-1)
                    .foregroundStyle(quota.status == .normal ? TM.textPrimary : resolvedTint)
                MeterBar(fraction: quota.fraction, tint: resolvedTint)
                    .accessibilityLabel("\(title)已用比例")
                    .accessibilityValue(quota.fraction.formatted(.percent.precision(.fractionLength(0))))
                Text(quota.resetAt.map(resetHintText) ?? " ")
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
                    .accessibilityHidden(quota.resetAt == nil)
            } else {
                Text("—")
                    .font(.system(size: numberSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(TM.textSecondary)
                Text("接口未返回")
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .tmCard()
    }
}

/// 余额 hero 卡：DeepSeek 余额与 Kimi 余额回退共用。
private struct BalanceHeroCard: View {
    let quota: Quota?
    var tint: Color = .blue
    var eyebrow: String = "可用余额"
    var note: String? = nil

    var body: some View {
        if let quota {
            HStack(spacing: 16) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
                VStack(alignment: .leading, spacing: 5) {
                    Text(eyebrow)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(TM.textTertiary)
                    Text(quota.remainingText)
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .tracking(-1)
                        .foregroundStyle(quota.status == .normal ? TM.textPrimary : quota.status.tint)
                    if quota.status != .normal {
                        StatusBadge(status: quota.status)
                    }
                    if let note {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(TM.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tmCard()
        } else {
            Text("暂无可显示的余额数据")
                .font(.system(size: 12))
                .foregroundStyle(TM.textSecondary)
        }
    }
}

private struct GenericDetailUsageView: View {
    let quotas: [Quota]

    var body: some View {
        if let primary = quotas.first {
            VStack(alignment: .leading, spacing: 12) {
                QuotaTile(title: primary.name, quota: primary)
                if quotas.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("其他额度")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(TM.textTertiary)
                        ForEach(quotas.dropFirst()) { quota in
                            SecondaryQuotaRow(quota: quota)
                        }
                    }
                    .padding(14)
                    .tmCard()
                }
            }
        } else {
            Text("暂无可显示的额度数据")
                .font(.system(size: 12))
                .foregroundStyle(TM.textSecondary)
        }
    }
}

private struct SecondaryQuotaRow: View {
    let quota: Quota

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TM.textSecondary)
                Spacer()
                Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(quota.status == .normal ? TM.textPrimary : quota.status.tint)
            }
            MeterBar(fraction: quota.fraction, tint: quota.status.tint, height: 5)
                .accessibilityLabel("\(quota.name)已用比例")
                .accessibilityValue(quota.fraction.formatted(.percent.precision(.fractionLength(0))))
        }
    }
}

struct SnapshotStatePanel: View {
    let snapshot: UsageSnapshot
    let message: String

    private var iconName: String {
        switch snapshot.state {
        case .unsupported: "questionmark.circle"
        case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
        case .notConfigured: "lock.trianglebadge.exclamationmark"
        default: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch snapshot.state {
        case .unsupported: "暂不支持额度接口"
        case .authenticationRequired: "认证已失效"
        case .notConfigured: "需要配置"
        default: "额度暂时不可用"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(snapshot.state.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TM.textPrimary)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(snapshot.state.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(snapshot.state.tint.opacity(0.2), lineWidth: 1))
    }
}

struct StatusBadge: View {
    let status: QuotaStatus

    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.13), in: Capsule())
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
