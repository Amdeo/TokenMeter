import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismissMenuBar

    private func openAddSubscription() {
        dismissMenuBar()
        AddSubscriptionWindow.show(store: store)
    }

    private func openDetails() {
        dismissMenuBar()
        openWindow(id: "details")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarHeader(
                subscriptionCount: store.orderedSubscriptions.count,
                isRefreshing: store.isRefreshing,
                lastRefreshAt: store.lastRefreshAt,
                onRefresh: { Task { await store.refreshAll() } }
            )

            Divider().padding(.vertical, 14)

            if store.orderedSubscriptions.isEmpty {
                MenuBarEmptyState { openAddSubscription() }
            } else {
                VStack(spacing: 10) {
                    ForEach(store.orderedSubscriptions) { subscription in
                        SubscriptionMenuCard(
                            subscription: subscription,
                            snapshot: store.snapshots[subscription.id]
                        )
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }

            Divider().padding(.vertical, 14)

            HStack(spacing: 10) {
                Button(action: openDetails) {
                    Label("打开详情", systemImage: "rectangle.stack")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button { openAddSubscription() } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.borderless)
                .help("添加订阅")

                Button(role: .destructive) {
                    store.stop()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .help("退出 TokenMeter")
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

private struct MenuBarHeader: View {
    let subscriptionCount: Int
    let isRefreshing: Bool
    let lastRefreshAt: Date?
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("TokenMeter")
                    .font(.headline)
                Text("\(subscriptionCount) 个订阅")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRefresh) {
                Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.body.weight(.medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .background(.thinMaterial, in: Circle())
            .disabled(isRefreshing)
            .help(lastRefreshAt.map { "上次更新：\($0.tokenMeterTimeText)" } ?? "刷新全部")
        }
    }
}

private struct MenuBarEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("添加第一个订阅")
                    .font(.headline)
                Text("连接一个账户，在菜单栏快速查看额度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("添加订阅", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SubscriptionMenuCard: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot?

    private var visibleStatus: QuotaStatus {
        guard let snapshot else { return .normal }
        switch subscription.platform {
        case .deepSeek:
            return snapshot.status(for: [.balance])
        case .kimi:
            let coreKinds: Set<Quota.Kind> = [.fiveHour, .weekly, .monthly]
            return snapshot.quotas.contains { coreKinds.contains($0.kind) }
                ? snapshot.status(for: coreKinds)
                : snapshot.status(for: [.balance])
        default:
            return snapshot.overallStatus
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                PlatformLogo(platform: subscription.platform, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(subscription.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(subscription.platform.rawValue) · \(subscription.authMethod.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if snapshot != nil {
                    Text(visibleStatus.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(visibleStatus.tint)
                }
            }

            if let snapshot, snapshot.errorMessage == nil {
                SubscriptionMenuUsageView(subscription: subscription, snapshot: snapshot)
            } else if let snapshot, let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(snapshot.state.tint)
                    .lineLimit(2)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("等待首次刷新…")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        )
    }
}

private struct SubscriptionMenuUsageView: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot

    @ViewBuilder
    var body: some View {
        switch subscription.platform {
        case .deepSeek:
            BalanceMenuRow(quota: snapshot.quotas.first { $0.kind == .balance })
        case .kimi:
            VStack(alignment: .leading, spacing: 10) {
                QuotaProgressRow(title: "5 小时额度", quota: snapshot.quotas.first { $0.kind == .fiveHour })
                QuotaProgressRow(title: "每周额度", quota: snapshot.quotas.first { $0.kind == .weekly })
                QuotaProgressRow(title: "月度额度", quota: snapshot.quotas.first { $0.kind == .monthly })
            }
        default:
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
        }
    }
}

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
