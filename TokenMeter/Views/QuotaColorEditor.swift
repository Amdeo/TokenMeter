import SwiftUI

// MARK: - 外观配置（卡片样式 + 配色）
// 从 SubscriptionEditorSheet.swift 拆出：卡片样式轮播、颜色目标推导、入口行、二级页面与配置行
// 自成一个内聚单元，也让编辑器文件回到仓库的 1000 行限制以内。

/// 颜色设置的可用性：卡片要么会画进度条，要么渲染余额数值（两者都可配颜色）。
/// 能力由卡片样式与供应商卡片 renderer 各自声明（见 `SubscriptionCardCapabilities`），
/// 因此两者都不具备的卡片才不展示设置，也不需要在这里写供应商分支。
enum QuotaColorSettings {
    /// 卡片是否会画出可配颜色的数值：样式与 renderer 的进度条能力，或 renderer 的余额数值能力。
    @MainActor
    static func isAvailable(style: SubscriptionCardStyle, providerID: ProviderID) -> Bool {
        let renderer = cardCapabilities(for: providerID)
        return SubscriptionCardCapabilities.renderProgressMeters(style: style.capabilities, renderer: renderer)
            || renderer.contains(.balanceValues)
    }

    /// 当前可配置的颜色目标；卡片既无进度条也不渲染余额时为空（页面不展示颜色行）。
    @MainActor
    static func targets(style: SubscriptionCardStyle, providerID: ProviderID, quotas: [Quota]) -> [QuotaColorTarget] {
        let renderer = cardCapabilities(for: providerID)
        var result: [QuotaColorTarget] = []
        if SubscriptionCardCapabilities.renderProgressMeters(style: style.capabilities, renderer: renderer) {
            result += QuotaColorTarget.progressTargets(providerID: providerID, quotas: quotas)
        }
        if renderer.contains(.balanceValues) {
            result += QuotaColorTarget.balanceTargets(quotas: quotas)
        }
        return result
    }

    /// 入口行的一句话摘要：已自定义项数或默认配色。
    static func summary(for colors: [String: UInt32]) -> String {
        colors.isEmpty ? "使用默认配色" : "已自定义 \(colors.count) 项"
    }

    @MainActor
    private static func cardCapabilities(for providerID: ProviderID) -> SubscriptionCardCapabilities {
        ProviderRegistry.definition(for: providerID)?.cardRenderer.capabilities ?? []
    }
}

/// 编辑页里的外观入口：样式与配色都在二级页里改，点按进入。
struct AppearanceEntryRow: View {
    let summary: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "paintbrush.pointed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? TM.accent : TM.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("外观")
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
        .accessibilityLabel("配置外观")
        .accessibilityValue(summary)
    }
}

// MARK: - 外观二级页

/// 从订阅编辑流程进入的外观页：卡片样式、配色与预览三类改动共用同一份
/// `SubscriptionEditorDraft`，返回后仍在编辑页，保存订阅时才落盘。
struct SubscriptionAppearancePage: View {
    @Environment(UsageStore.self) private var store
    @Bindable var draft: SubscriptionEditorDraft
    let onBack: () -> Void

    private var providerDefinition: any ProviderDefinition {
        ProviderRegistry.definition(for: draft.providerID) ?? UnsupportedProviderDefinition(providerID: draft.providerID)
    }

    private var targets: [QuotaColorTarget] {
        QuotaColorSettings.targets(
            style: draft.cardStyle,
            providerID: draft.providerID,
            quotas: snapshot?.quotas ?? []
        )
    }

    /// 当前样式的配色绑定：颜色改动只落在当前样式上，切换样式后各自保留。
    private var currentColors: Binding<[String: UInt32]> {
        Binding(get: { draft.currentQuotaColors }, set: { draft.currentQuotaColors = $0 })
    }

    /// 预览用订阅：沿用草稿的卡片样式与颜色，改动即时反映到预览卡片上。
    /// 没有真实数据时预览的是 renderer 的示例快照，认证方式随之取预览形态
    /// （否则 Kimi 的总使用量锚点与下方的样式轮播预览不一致）。
    private var previewSubscription: Subscription {
        var subscription = draft.original
            ?? Subscription(providerID: draft.providerID, name: previewName, authMethodID: draft.authMethodID)
        if snapshot?.state != .realtime {
            subscription.authMethodID = CardStyleCarouselPicker.previewAuthMethod(for: draft.providerID)
        }
        subscription.cardStyle = draft.cardStyle
        subscription.quotaColors = draft.quotaColors
        return subscription
    }

    /// 真实快照：只有编辑已有订阅且该订阅已抓到数据时才有。
    private var snapshot: UsageSnapshot? {
        draft.original.flatMap { store.snapshots[$0.id] }
    }

    /// 有真实数据就用真实卡片，否则用 renderer 的示例快照（形态与该供应商真实卡片一致）。
    private var previewSnapshot: UsageSnapshot {
        if let snapshot, snapshot.state == .realtime { return snapshot }
        return providerDefinition.cardRenderer.sampleSnapshot(subscription: previewSubscription)
    }

    private var previewName: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? providerDefinition.metadata.displayName : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                definition: providerDefinition,
                title: "外观",
                subtitle: "「\(draft.cardStyle.title)」样式 · 保存订阅后生效",
                onBack: onBack
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppearanceSection(title: "预览") {
                        SubscriptionMenuCard(subscription: previewSubscription, snapshot: previewSnapshot, onEdit: {})
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    AppearanceSection(title: "卡片样式", subtitle: "左右滑动预览，点按卡片或圆点选择。") {
                        CardStyleCarouselPicker(
                            selection: $draft.cardStyle,
                            providerID: draft.providerID,
                            displayName: previewName
                        )
                    }
                    AppearanceSection(title: "颜色") {
                        QuotaColorEditor(colors: currentColors, targets: targets)
                    }
                }
                .padding(.vertical, 18)
                .reportsIntrinsicPanelHeight(route: .appearance, chrome: PanelLayoutMetrics.pageChrome)
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
}

/// 外观页的分区标题 + 内容。
private struct AppearanceSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(TM.textTertiary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
            }
            content()
        }
    }
}

// MARK: - 卡片样式轮播选择器

/// 横向分页轮播：每页渲染一张真实 `SubscriptionMenuCard` 预览（当前供应商的示例额度），
/// 滑动/点按切换草稿的卡片样式。预览不读写任何真实订阅数据。
struct CardStyleCarouselPicker: View {
    @Binding var selection: SubscriptionCardStyle
    let providerID: ProviderID
    let displayName: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleID: String?

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(SubscriptionCardStyle.allCases) { style in
                        previewCard(for: style)
                            .padding(.horizontal, 10)
                            .containerRelativeFrame(.horizontal)
                            .id(style.rawValue)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleID)
            .scrollIndicators(.hidden)
            .frame(height: 190)
            .background(TM.fieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(TM.border, lineWidth: 1)
            )

            Text(selection.title)
                .font(.system(size: 11, weight: .semibold))
            Text(selection.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(TM.textSecondary)

            HStack(spacing: 6) {
                ForEach(SubscriptionCardStyle.allCases) { style in
                    Circle()
                        .fill(style == selection ? TM.textPrimary : TM.border)
                        .frame(width: 6, height: 6)
                        .contentShape(Rectangle().size(width: 16, height: 16))
                        .onTapGesture { select(style) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("卡片样式")
            .accessibilityValue(selection.title)
        }
        .frame(maxWidth: .infinity)
        .onAppear { visibleID = selection.rawValue }
        .onChange(of: visibleID) { _, new in
            guard let new, let style = SubscriptionCardStyle(rawValue: new), style != selection else { return }
            selection = style
        }
        .onChange(of: selection) { _, new in
            guard visibleID != new.rawValue else { return }
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) { visibleID = new.rawValue }
        }
    }

    private func select(_ style: SubscriptionCardStyle) {
        withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) { visibleID = style.rawValue }
        selection = style
    }

    /// 预览卡：示例快照由当前供应商的 renderer 给出，形态与真实卡片一致；
    /// 认证方式取该供应商的非 API Key 形态（订阅制最完整），否则用默认项。
    private func previewCard(for style: SubscriptionCardStyle) -> some View {
        let subscription = Subscription(
            providerID: providerID,
            name: displayName,
            authMethodID: Self.previewAuthMethod(for: providerID),
            cardStyle: style
        )
        let renderer = ProviderRegistry.definition(for: providerID)?.cardRenderer ?? BalanceCardRenderer()
        return SubscriptionMenuCard(subscription: subscription, snapshot: renderer.sampleSnapshot(subscription: subscription)) {
            select(style)
        }
        .allowsHitTesting(true)
    }

    /// 预览用认证方式：优先非 API Key 形态（如 Kimi 订阅制的总使用量锚点在 API Key 形态下不显示），
    /// 只有 API Key 的供应商（如 DeepSeek）保持默认选择。
    static func previewAuthMethod(for providerID: ProviderID) -> AuthMethodID {
        let methods = ProviderRegistry.definition(for: providerID)?.authMethods ?? []
        return methods.first { $0.flowID != .apiKey }?.id
            ?? ProviderRegistry.defaultAuthMethod(for: providerID)
            ?? .apiKey
    }
}

/// 颜色目标：编辑页里每个可配置数值的稳定键、展示名与内置默认色。
/// `name` 与 `kind` 用于沿完整解析链（name → kind → generic → 内置默认）计算显示色，
/// 与概览页保持一致；overall 目标通过 `isOverall` 走 `resolveOverall`。
struct QuotaColorTarget: Identifiable {
    let key: String
    let label: String
    let defaultColor: Color
    let name: String?
    let kind: Quota.Kind?
    let isOverall: Bool
    /// 数值样例文本（余额目标用）；nil 时预览渲染迷你进度条。
    let previewText: String?
    var id: String { key }

    init(
        key: String,
        label: String,
        defaultColor: Color,
        name: String? = nil,
        kind: Quota.Kind? = nil,
        isOverall: Bool = false,
        previewText: String? = nil
    ) {
        self.key = key
        self.label = label
        self.defaultColor = defaultColor
        self.name = name
        self.kind = kind
        self.isOverall = isOverall
        self.previewText = previewText
    }

    /// 进度条目标：按供应商与当前快照额度生成；余额没有进度条，不参与。
    @MainActor
    static func progressTargets(providerID: ProviderID, quotas: [Quota]) -> [QuotaColorTarget] {
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

    /// 余额数值目标：快照里有余额就逐条配置，没有快照（新建订阅）时给一个语义键兜底目标。
    /// 未配置时显示文字主色（余额数值的本来观感），配置后才走解析链。
    static func balanceTargets(quotas: [Quota]) -> [QuotaColorTarget] {
        let balances = quotas.filter { $0.kind == .balance }
        guard !balances.isEmpty else {
            return [QuotaColorTarget(
                key: SubscriptionQuotaColors.balanceKey,
                label: "余额数值",
                defaultColor: TM.textPrimary,
                kind: .balance,
                previewText: balanceSampleText
            )]
        }
        return balances.map { quota in
            QuotaColorTarget(
                key: SubscriptionQuotaColors.nameKey(quota.name),
                label: quota.name,
                defaultColor: TM.textPrimary,
                name: quota.name,
                kind: .balance,
                previewText: quota.remainingText
            )
        }
    }

    /// 无快照时余额目标的数值样例（与样式预览里的示例余额一致）。
    private static let balanceSampleText = "CNY 18.42"
}

/// 颜色编辑列表：把 draft 的颜色字典绑定到每个颜色目标。
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

    /// 该目标是否已在解析链上配过色；未配置时显示目标自己的默认色
    /// （进度条目标等于解析链末端默认色，余额目标是文字主色）。
    private var isConfigured: Bool {
        SubscriptionQuotaColors.hasConfiguration(colors, name: target.name ?? "", kind: target.kind ?? .generic)
    }

    /// 显示色：overall 走聚合解析链；其余“已配置走解析链、未配置显示默认色”，与概览页一致。
    private var resolvedColor: Color {
        if target.isOverall {
            return SubscriptionQuotaColors.resolveOverall(colors)
        }
        guard isConfigured else { return target.defaultColor }
        return SubscriptionQuotaColors.resolve(colors, name: target.name ?? "", kind: target.kind ?? .generic)
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

    /// 实时预览：余额目标是数值样例文本，进度条目标是约 60% 的细轨道 + 同色百分比，
    /// 两者都用解析色，直观展示文字/进度条与百分比严格同色。
    @ViewBuilder
    private var preview: some View {
        if let text = target.previewText {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(resolvedColor)
        } else {
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
}
