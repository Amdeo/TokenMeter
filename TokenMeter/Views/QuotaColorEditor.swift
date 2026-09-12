import SwiftUI

// MARK: - 进度条颜色配置
// 从 SubscriptionEditorSheet.swift 拆出：颜色目标推导与配置行自成一个内聚单元，
// 也让编辑器文件回到仓库的 1000 行限制以内。


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
