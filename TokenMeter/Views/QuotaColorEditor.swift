import SwiftUI

// MARK: - 进度条颜色配置
// 从 SubscriptionEditorSheet.swift 拆出：颜色目标推导、入口行、二级页面与配置行自成一个内聚单元，
// 也让编辑器文件回到仓库的 1000 行限制以内。

/// 进度条颜色设置的可用性：颜色只属于「会画进度条」的卡片。
/// 能力由卡片样式与供应商卡片 renderer 各自声明（见 `SubscriptionCardCapabilities`），
/// 因此没有进度条的卡片（如余额型）不会展示设置，也不需要在这里写供应商分支。
enum QuotaColorSettings {
    /// 卡片是否会画出进度条：卡片样式与供应商卡片 renderer 都必须声明能力。
    /// 颜色设置入口与紧凑样式的汇总条都用它判定，因此没有进度条的卡片既不提供设置也不画汇总条。
    @MainActor
    static func isAvailable(style: SubscriptionCardStyle, providerID: ProviderID) -> Bool {
        SubscriptionCardCapabilities.renderProgressMeters(
            style: style.capabilities,
            renderer: ProviderRegistry.definition(for: providerID)?.cardRenderer.capabilities ?? []
        )
    }

    /// 当前可配置的颜色目标；卡片不支持进度条时为空（页面不展示任何颜色行）。
    @MainActor
    static func targets(style: SubscriptionCardStyle, providerID: ProviderID, quotas: [Quota]) -> [QuotaColorTarget] {
        guard isAvailable(style: style, providerID: providerID) else { return [] }
        return QuotaColorTarget.targets(providerID: providerID, quotas: quotas)
    }

    /// 入口行的一句话摘要：已自定义项数或默认配色。
    static func summary(for colors: [String: UInt32]) -> String {
        colors.isEmpty ? "使用默认配色" : "已自定义 \(colors.count) 项"
    }
}

/// 编辑页里的颜色设置入口：只在卡片支持进度条时出现，点按进入颜色二级页面。
struct QuotaColorEntryRow: View {
    let summary: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? TM.accent : TM.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("进度条颜色")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TM.textPrimary)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TM.textTertiary)
            }
            .padding(.horizontal, TM.cardContentHorizontal)
            .padding(.vertical, 9)
            .background(hovering ? TM.cardFillHover : TM.fieldFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hovering ? TM.borderStrong : TM.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("配置进度条颜色")
        .accessibilityValue(summary)
    }
}

// MARK: - 进度条颜色二级页面

/// 从订阅编辑流程进入的颜色页面：编辑的是同一份 `SubscriptionEditorDraft`，
/// 顶部按当前卡片样式实时预览改动，返回后仍在编辑页，保存订阅时才落盘。
struct QuotaColorsPage: View {
    @Environment(UsageStore.self) private var store
    @Bindable var draft: SubscriptionEditorDraft
    let onBack: () -> Void

    private var providerDefinition: any ProviderDefinition {
        ProviderRegistry.definition(for: draft.providerID) ?? UnsupportedProviderDefinition(providerID: draft.providerID)
    }

    private var snapshot: UsageSnapshot? {
        draft.original.flatMap { store.snapshots[$0.id] }
    }

    private var targets: [QuotaColorTarget] {
        QuotaColorSettings.targets(style: draft.cardStyle, providerID: draft.providerID, quotas: snapshot?.quotas ?? [])
    }

    /// 当前样式的配色绑定：颜色改动只落在当前样式上，切换样式后各自保留。
    private var currentColors: Binding<[String: UInt32]> {
        Binding(get: { draft.currentQuotaColors }, set: { draft.currentQuotaColors = $0 })
    }

    /// 预览用订阅：沿用草稿的卡片样式与颜色，颜色改动即时反映到预览卡片上。
    private var previewSubscription: Subscription {
        var subscription = draft.original
            ?? Subscription(providerID: draft.providerID, name: previewName, authMethodID: draft.authMethodID)
        subscription.cardStyle = draft.cardStyle
        subscription.quotaColors = draft.quotaColors
        return subscription
    }

    private var previewName: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? providerDefinition.metadata.displayName : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                definition: providerDefinition,
                title: "进度条颜色",
                subtitle: "「\(draft.cardStyle.title)」样式 · 保存订阅后生效",
                onBack: onBack
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let snapshot, snapshot.state == .realtime {
                        stylePreview(snapshot)
                    }
                    QuotaColorEditor(colors: currentColors, targets: targets)
                }
                .padding(.vertical, 18)
                .reportsIntrinsicPanelHeight(route: .quotaColors, chrome: PanelLayoutMetrics.pageChrome)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 10) {
                Spacer()
                Button("完成", action: onBack)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 12)).padding(.top, 10).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 当前样式的实时预览：颜色改动直接落在真实卡片上，不用想象效果。
    private func stylePreview(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("样式预览")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(TM.textTertiary)
            SubscriptionMenuCard(subscription: previewSubscription, snapshot: snapshot, onEdit: {})
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}


/// 颜色目标：编辑页里每个可配置额度的稳定键、展示名与内置默认色。
/// `name` 与 `kind` 用于沿完整解析链（name → kind → generic → 内置默认）计算显示色，
/// 与概览页保持一致；overall 目标通过 `isOverall` 走 `resolveOverall`。
struct QuotaColorTarget: Identifiable {
    let key: String
    let label: String
    let defaultColor: Color
    let name: String?
    let kind: Quota.Kind?
    let isOverall: Bool
    var id: String { key }

    init(
        key: String,
        label: String,
        defaultColor: Color,
        name: String? = nil,
        kind: Quota.Kind? = nil,
        isOverall: Bool = false
    ) {
        self.key = key
        self.label = label
        self.defaultColor = defaultColor
        self.name = name
        self.kind = kind
        self.isOverall = isOverall
    }

    /// 按供应商与当前快照额度生成颜色目标列表；余额没有进度条，不参与配置。
    @MainActor
    static func targets(providerID: ProviderID, quotas: [Quota]) -> [QuotaColorTarget] {
        var result: [QuotaColorTarget] = []
        let definition = ProviderRegistry.definition(for: providerID)
        // 存在「总使用量」聚合额度的供应商（如 Kimi）额外提供 overall 目标。
        if let overallLabel = definition?.metadata.overallUsageLabel {
            result.append(QuotaColorTarget(
                key: SubscriptionQuotaColors.overallKey,
                label: overallLabel,
                defaultColor: SubscriptionQuotaColors.overallDefault,
                isOverall: true
            ))
        }
        let progressQuotas = quotas.filter { $0.kind != .balance }
        if progressQuotas.isEmpty {
            if definition?.metadata.overallUsageLabel != nil {
                result.append(QuotaColorTarget(
                    key: SubscriptionQuotaColors.fiveHourKey,
                    label: "5 小时额度",
                    defaultColor: SubscriptionQuotaColors.defaultColor(forKind: .fiveHour),
                    name: "5 小时额度",
                    kind: .fiveHour
                ))
                result.append(QuotaColorTarget(
                    key: SubscriptionQuotaColors.weeklyKey,
                    label: "每周额度",
                    defaultColor: SubscriptionQuotaColors.defaultColor(forKind: .weekly),
                    name: "每周额度",
                    kind: .weekly
                ))
            }
        } else {
            for quota in progressQuotas {
                result.append(QuotaColorTarget(
                    key: SubscriptionQuotaColors.nameKey(quota.name),
                    label: quota.name,
                    defaultColor: SubscriptionQuotaColors.defaultColor(forKind: quota.kind),
                    name: quota.name,
                    kind: quota.kind
                ))
            }
        }
        // 批量默认色：作用于所有未单独配置的额度窗口。
        result.append(QuotaColorTarget(
            key: SubscriptionQuotaColors.genericKey,
            label: "默认颜色",
            defaultColor: SubscriptionQuotaColors.defaultColor(forKind: .generic)
        ))
        return result
    }
}

/// 进度条颜色编辑列表：把 draft 的颜色字典绑定到每个颜色目标。
struct QuotaColorEditor: View {
    @Binding var colors: [String: UInt32]
    let targets: [QuotaColorTarget]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(targets) { target in
                QuotaColorRow(
                    target: target,
                    colors: colors,
                    onSelect: { colors[target.key] = $0 },
                    onReset: { colors[target.key] = nil }
                )
            }
        }
    }
}

/// 单个颜色目标的紧凑配置行：名称、当前色样本、预设色、自定义选择器与实时预览。
struct QuotaColorRow: View {
    let target: QuotaColorTarget
    let colors: [String: UInt32]
    let onSelect: (UInt32) -> Void
    let onReset: () -> Void

    private var rgb: UInt32? { colors[target.key] }

    /// 显示色沿完整解析链（name → kind → generic → 内置默认）计算，与概览页一致；
    /// generic 目标没有 name/kind，直接显示自身值或默认色。
    private var resolvedColor: Color {
        if target.isOverall {
            return SubscriptionQuotaColors.resolveOverall(colors)
        }
        if let name = target.name, let kind = target.kind {
            return SubscriptionQuotaColors.resolve(colors, name: name, kind: kind)
        }
        return rgb.map { Color(hex: $0) } ?? target.defaultColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(target.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TM.textPrimary)
                    .lineLimit(1)
                Circle()
                    .fill(resolvedColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(TM.borderStrong, lineWidth: 1))
                Spacer(minLength: 6)
                if rgb != nil {
                    Button("恢复默认", action: onReset)
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(TM.textSecondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(SubscriptionQuotaColors.presets, id: \.self) { preset in
                    Button { onSelect(preset) } label: {
                        Circle()
                            .fill(Color(hex: preset))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().strokeBorder(
                                    rgb == preset ? TM.textPrimary : TM.border,
                                    lineWidth: rgb == preset ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预设颜色")
                }
                ColorPicker("", selection: Binding(
                    get: { resolvedColor },
                    set: { onSelect($0.tokenMeterRGB) }
                ), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.mini)
            }
            preview
        }
    }

    /// 小型实时预览：约 60% 的细轨道与同色百分比，直观展示进度条与百分比严格同色。
    private var preview: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(TM.meterTrack)
                    Capsule()
                        .fill(resolvedColor)
                        .frame(width: proxy.size.width * 0.6)
                }
            }
            .frame(height: 4)
            Text("60%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(resolvedColor)
        }
    }
}
