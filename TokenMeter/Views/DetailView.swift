import SwiftUI

struct DetailView: View {
    @Environment(UsageStore.self) private var store
    @State private var renaming: Subscription?
    @State private var renameDraft = ""
    @State private var importingSubscriptionID: UUID?
    @State private var importMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeroHeader(
                    subscriptionCount: store.orderedSubscriptions.count,
                    lastRefreshAt: store.lastRefreshAt,
                    isRefreshing: store.isRefreshing,
                    onRefresh: { Task { await store.refreshAll() } },
                    onAdd: { AddSubscriptionWindow.show(store: store) }
                )

                if store.orderedSubscriptions.isEmpty {
                    DetailEmptyState { AddSubscriptionWindow.show(store: store) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16)], spacing: 16) {
                        ForEach(store.orderedSubscriptions) { subscription in
                            SubscriptionCard(
                                subscription: subscription,
                                snapshot: store.snapshots[subscription.id],
                                onRename: {
                                    renameDraft = subscription.name
                                    renaming = subscription
                                },
                                onUpdateCredentials: {
                                    AddSubscriptionWindow.show(store: store, editingSubscription: subscription)
                                },
                                onImportBrowserSession: {
                                    importBrowserSession(for: subscription)
                                },
                                isImportingBrowserSession: importingSubscriptionID == subscription.id,
                                onDelete: { store.remove(subscription) },
                                onRefresh: { Task { await store.refresh(subscription) } }
                            )
                        }
                    }
                }
            }
            .padding(32)
        }
        .frame(minWidth: 700, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("重命名订阅", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $renameDraft)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let renaming, !renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.rename(renaming, to: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                self.renaming = nil
            }
        }
        .navigationTitle("我的订阅")
        .alert("Chrome 导入", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("好") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func importBrowserSession(for subscription: Subscription) {
        guard importingSubscriptionID == nil else { return }
        importingSubscriptionID = subscription.id
        Task { @MainActor in
            defer { importingSubscriptionID = nil }
            do {
                let credential = try await Task.detached {
                    try await ChromeSessionImporter().importCredential()
                }.value
                try CredentialStore().save(browserCredential: credential, for: subscription.id)
                var updatedSubscription = subscription
                updatedSubscription.authMethod = .kimiBrowserSession
                store.updateAuthMethod(subscription, to: .kimiBrowserSession)
                await store.refresh(updatedSubscription)
                importMessage = "已从 Chrome 导入 Kimi 网页登录态，额度已刷新。"
            } catch is CancellationError {
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }
}

private struct DetailHeroHeader: View {
    let subscriptionCount: Int
    let lastRefreshAt: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Label("TokenMeter", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("我的订阅")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                HStack(spacing: 7) {
                    Text("\(subscriptionCount) 个订阅")
                    Text("·")
                    Text(lastRefreshAt.map { "更新于 \($0.tokenMeterTimeText)" } ?? "尚未更新")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Label("凭证只保存在 TokenMeter 本地私有文件；订阅文件只保存元数据。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: onRefresh) {
                    Label(isRefreshing ? "刷新中…" : "刷新全部", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                Button(action: onAdd) {
                    Label("添加订阅", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.bottom, 4)
    }
}

private struct DetailEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 78, height: 78)
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 6) {
                Text("从一个订阅开始")
                    .font(.title2.weight(.semibold))
                Text("连接你的 AI 账户，在一个安静的空间里掌握额度。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("添加第一个订阅", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.accentColor.opacity(0.12)))
    }
}

private struct SubscriptionCard: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot?
    let onRename: () -> Void
    let onUpdateCredentials: () -> Void
    let onImportBrowserSession: () -> Void
    let isImportingBrowserSession: Bool
    let onDelete: () -> Void
    let onRefresh: () -> Void

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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                PlatformLogo(platform: subscription.platform, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(subscription.name).font(.headline).lineLimit(1)
                    Text("\(subscription.platform.rawValue) · \(subscription.authMethod.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot != nil { StatusBadge(status: visibleStatus) }
            }

            if let snapshot {
                if let error = snapshot.errorMessage {
                    SnapshotStatePanel(snapshot: snapshot, message: error)
                } else {
                    ProviderDetailUsageView(subscription: subscription, snapshot: snapshot)
                }
                Text("最近更新：\(snapshot.updatedAt.tokenMeterTimeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("等待首次刷新…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            }

            Divider()
            HStack(spacing: 14) {
                Button("重命名", action: onRename).buttonStyle(.borderless)
                if subscription.platform == .kimi {
                    Button(isImportingBrowserSession ? "导入中…" : "从 Chrome 导入", action: onImportBrowserSession)
                        .buttonStyle(.borderless)
                        .disabled(isImportingBrowserSession)
                }
                if snapshot?.state == .notConfigured {
                    Button("更新凭证", action: onUpdateCredentials).buttonStyle(.borderless)
                }
                Button("删除", role: .destructive, action: onDelete).buttonStyle(.borderless)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
            .font(.caption)
        }
        .padding(19)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct ProviderDetailUsageView: View {
    let subscription: Subscription
    let snapshot: UsageSnapshot

    @ViewBuilder
    var body: some View {
        switch subscription.platform {
        case .deepSeek:
            DeepSeekBalanceView(quota: snapshot.quotas.first { $0.kind == .balance })
        case .kimi:
            KimiDetailUsageView(snapshot: snapshot)
        default:
            GenericDetailUsageView(quotas: snapshot.quotas)
        }
    }
}

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

private struct SnapshotStatePanel: View {
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
