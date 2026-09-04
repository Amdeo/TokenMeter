import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.dismiss) private var dismissMenuBar

    private func openAddSubscription() {
        dismissMenuBar()
        SubscriptionEditorWindow.show(store: store)
    }

    private func openEditor(for subscription: Subscription) {
        dismissMenuBar()
        SubscriptionEditorWindow.show(store: store, subscription: subscription)
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
                            snapshot: store.snapshots[subscription.id],
                            onEdit: { openEditor(for: subscription) }
                        )
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }

            Divider().padding(.vertical, 14)

            HStack(spacing: 10) {
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
    let onEdit: () -> Void
    @State private var isHovering = false

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
                if isHovering {
                    Button(action: onEdit) {
                        Image(systemName: "gearshape")
                            .font(.subheadline)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("编辑订阅")
                } else if snapshot != nil {
                    Text(visibleStatus.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(visibleStatus.tint)
                }
            }

            if let snapshot, snapshot.errorMessage == nil {
                SubscriptionUsageView(subscription: subscription, snapshot: snapshot, style: .compact)
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
        .onHover { isHovering = $0 }
    }

    private var visibleStatus: QuotaStatus {
        guard let snapshot else { return .normal }
        return snapshot.visibleStatus(for: subscription)
    }
}
