import SwiftUI

// 订阅用量数据的共享展示组件：菜单栏面板（.compact）与订阅编辑窗口（.full）复用同一套渲染逻辑。
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
                DeepSeekBalanceView(quota: snapshot.quotas.first { $0.kind == .balance })
            }
        case .kimi:
            if style == .compact {
                VStack(alignment: .leading, spacing: 10) {
                    QuotaProgressRow(title: "5 小时额度", quota: snapshot.quotas.first { $0.kind == .fiveHour })
                    QuotaProgressRow(title: "每周额度", quota: snapshot.quotas.first { $0.kind == .weekly })
                    QuotaProgressRow(title: "月度额度", quota: snapshot.quotas.first { $0.kind == .monthly })
                }
            } else {
                KimiDetailUsageView(snapshot: snapshot)
            }
        default:
            if style == .compact {
                if snapshot.quotas.isEmpty {
                    Text("暂无可显示的额度数据")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
            let coreKinds: Set<Quota.Kind> = [.fiveHour, .weekly, .monthly]
            return quotas.contains { coreKinds.contains($0.kind) }
                ? status(for: coreKinds)
                : status(for: [.balance])
        default:
            return overallStatus
        }
    }
}

// MARK: - 紧凑行（菜单栏面板）

private struct BalanceMenuRow: View {
    let quota: Quota?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("可用余额")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(quota?.remainingText ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(quota?.status.tint ?? .secondary)
        }
    }
}

private struct QuotaProgressRow: View {
    let title: String
    let quota: Quota?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let quota {
                    Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(quota.status.tint)
                } else {
                    Text("—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let quota {
                ProgressView(value: quota.fraction)
                    .tint(quota.status.tint)
                    .controlSize(.small)
                    .accessibilityLabel("\(title)已用比例")
                    .accessibilityValue(quota.fraction.formatted(.percent.precision(.fractionLength(0))))
            } else {
                Text("接口未返回")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 完整展示（编辑窗口）

private struct DeepSeekBalanceView: View {
    let quota: Quota?

    var body: some View {
        if let quota {
            VStack(alignment: .leading, spacing: 8) {
                Text("可用余额")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(quota.remainingText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                if quota.status != .normal {
                    Text(quota.status.label)
                        .font(.caption)
                        .foregroundStyle(quota.status.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(quota.status.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            Text("暂无可显示的余额数据")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct KimiDetailUsageView: View {
    let snapshot: UsageSnapshot

    private var coreKinds: Set<Quota.Kind> { [.fiveHour, .weekly, .monthly] }
    private var hasCoreQuota: Bool { snapshot.quotas.contains { coreKinds.contains($0.kind) } }
    private func quota(_ kind: Quota.Kind) -> Quota? { snapshot.quotas.first { $0.kind == kind } }

    @ViewBuilder
    var body: some View {
        if !hasCoreQuota, let balance = quota(.balance) {
            VStack(alignment: .leading, spacing: 8) {
                Text("余额模式")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("当前使用 Moonshot 余额接口")
                    .font(.subheadline.weight(.medium))
                Text(balance.remainingText)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                Text("Coding 三档额度暂不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            VStack(spacing: 12) {
                if let ratio = snapshot.overallUsageRatio {
                    KimiOverallUsageQuota(ratio: ratio)
                }
                KimiHeroQuota(title: "5 小时额度", quota: quota(.fiveHour))
                HStack(alignment: .top, spacing: 10) {
                    KimiQuotaTile(title: "每周额度", quota: quota(.weekly))
                    KimiQuotaTile(title: "月度额度", quota: quota(.monthly))
                }
            }
        }
    }
}

private struct KimiOverallUsageQuota: View {
    let ratio: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("总使用量")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(ratio, format: .percent.precision(.fractionLength(1)))
                    .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ratio >= 0.8 ? Color.orange : Color.accentColor)
            }
            ProgressView(value: ratio)
                .tint(ratio >= 0.8 ? .orange : .accentColor)
            Text("来自 Kimi 网页订阅统计")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct KimiHeroQuota: View {
    let title: String
    let quota: Quota?

    var body: some View {
        if let quota {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(quota.status.tint)
                }
                ProgressView(value: quota.fraction).tint(quota.status.tint)
                if let resetAt = quota.resetAt {
                    Text("重置\(resetAt.tokenMeterResetText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(quota.status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            MissingQuotaView(title: title)
        }
    }
}

private struct KimiQuotaTile: View {
    let title: String
    let quota: Quota?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                if let quota {
                    Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(quota.status.tint)
                }
            }
            if let quota {
                ProgressView(value: quota.fraction).tint(quota.status.tint)
                if let resetAt = quota.resetAt {
                    Text("重置\(resetAt.tokenMeterResetText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("接口未返回")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MissingQuotaView: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.medium))
            Text("接口未返回")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct GenericDetailUsageView: View {
    let quotas: [Quota]

    var body: some View {
        if let primary = quotas.first {
            VStack(alignment: .leading, spacing: 12) {
                PrimaryQuotaView(quota: primary)
                if quotas.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("其他额度").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(quotas.dropFirst()) { quota in SecondaryQuotaView(quota: quota) }
                    }
                }
            }
        } else {
            Text("暂无可显示的额度数据")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PrimaryQuotaView: View {
    let quota: Quota

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(quota.name).font(.subheadline.weight(.medium))
                Spacer()
                Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(quota.status.tint)
            }
            ProgressView(value: quota.fraction).tint(quota.status.tint).controlSize(.regular)
            if let resetAt = quota.resetAt {
                Text("重置\(resetAt.tokenMeterResetText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(quota.status.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct SecondaryQuotaView: View {
    let quota: Quota

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(quota.name).font(.caption)
                Spacer()
                Text(quota.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(quota.status.tint)
            }
            ProgressView(value: quota.fraction).tint(quota.status.tint)
        }
    }
}

struct SnapshotStatePanel: View {
    let snapshot: UsageSnapshot
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: snapshot.state == .unsupported ? "questionmark.circle" : "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(snapshot.state.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.state == .unsupported ? "暂不支持额度接口" : "额度暂时不可用")
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(snapshot.state.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StatusBadge: View {
    let status: QuotaStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.11), in: Capsule())
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
        case .normal: .green
        case .warning: .orange
        case .exhausted, .error: .red
        }
    }
}
