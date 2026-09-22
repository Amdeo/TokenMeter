import SwiftUI

/// 订阅编辑页里的「悬浮条」分区：这条订阅在条上显不显示、环追踪哪个额度、环什么颜色。
///
/// 移植自 Pulse 每账号设置里的 `Panel` 分组（`SettingsView.accountPaneBody`）。
/// 它挂在 `SubscriptionEditorContent` 里，所以面板的 TM-04/TM-05 与设置窗口的订阅子页
/// 共用同一块配置——一份设置，两个入口。
///
/// 改动只落在草稿上，和卡片样式、配色一样，保存订阅时才写回订阅本身。
struct SubscriptionRailSection: View {
    @Environment(UsageStore.self) private var store
    @Bindable var draft: SubscriptionEditorDraft

    var body: some View {
        SheetSection(title: "悬浮条", subtitle: "这条订阅在悬浮条上的环，保存订阅后生效。") {
            VStack(spacing: 8) {
                RailSettingRow(
                    title: "在悬浮条中显示",
                    subtitle: "关闭后这条订阅不出现在悬浮条上；全部关闭时悬浮条会隐藏。"
                ) {
                    Toggle("", isOn: $draft.rail.showsInRail)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                RailSettingRow(
                    title: "环显示",
                    subtitle: "这个环追踪哪个额度。"
                ) {
                    Picker("", selection: trackedWindow) {
                        Text("用量最高").tag(String?.none)

                        // 「总使用量」是供应商的聚合比例，不是额度窗口，所以单独一项。
                        if let overallLabel = overallUsageLabel {
                            Text(overallLabel).tag(String?.some(SubscriptionRailSettings.overallKey))
                        }
                        ForEach(windowNames, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 150, alignment: .trailing)
                    // 只有「用量最高」一项时没什么可选的：一个只能选自动的下拉
                    // 读起来像坏了，不如让它显式地不可用。
                    .disabled(windowNames.isEmpty && overallUsageLabel == nil)
                }

                RailSettingRow(
                    title: "环颜色",
                    subtitle: draft.rail.tintRGB == nil
                        ? "按用量状态取色：够用是绿的，快用完转橙，用尽转红。"
                        : "这个环一直用你选的颜色；额度用尽时仍然是红的。"
                ) {
                    Picker("", selection: usesCustomTint) {
                        Text("自动").tag(false)
                        Text("自定义").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }

                // 只有选了自定义才出现色板：自动时它是一片和当前状态无关的颜色。
                if draft.rail.tintRGB != nil {
                    RailTintPicker(rgb: customTint)
                        .padding(.horizontal, TM.cardContentHorizontal)
                }
            }
        }
    }

    // MARK: - 可选的额度

    /// 这次读数里的额度窗口名。余额不在其中：它没有比例可画，环画的是数字。
    private var windowNames: [String] {
        guard let id = draft.original?.id, let snapshot = store.snapshots[id] else { return [] }
        return snapshot.quotas.filter { $0.kind != .balance }.map(\.name)
    }

    private var overallUsageLabel: String? {
        ProviderRegistry.definition(for: draft.providerID)?.metadata.overallUsageLabel
    }

    /// 钉住的窗口要按**现在的**选项判断存不存在：供应商换了窗口名之后
    /// 下拉要落回「用量最高」，而不是停在一个已经不画任何东西的选择上（Pulse 同一条规则）。
    /// 落回显示不会改写订阅里存的值，用户主动选「用量最高」才清掉它。
    private var trackedWindow: Binding<String?> {
        Binding(
            get: {
                guard let pinned = draft.rail.trackedWindow else { return nil }
                if pinned == SubscriptionRailSettings.overallKey { return overallUsageLabel == nil ? nil : pinned }
                return windowNames.contains(pinned) ? pinned : nil
            },
            set: { draft.rail.trackedWindow = $0 }
        )
    }

    // MARK: - 环的颜色

    private var usesCustomTint: Binding<Bool> {
        Binding(
            get: { draft.rail.tintRGB != nil },
            // 切过去时落在一个看得见变化的具体颜色上，而不是让色板停在一个
            // 与「自动」当时恰好画着的颜色一样的位置——那样切过去像没生效。
            set: { draft.rail.tintRGB = $0 ? (draft.rail.tintRGB ?? SubscriptionQuotaColors.defaultRingTint) : nil }
        )
    }

    private var customTint: Binding<UInt32> {
        Binding(
            get: { draft.rail.tintRGB ?? SubscriptionQuotaColors.defaultRingTint },
            set: { draft.rail.tintRGB = $0 }
        )
    }
}

/// 一行设置：左边标签（可带说明），右边控件。
///
/// 用编辑器自己的形状而不是设置窗口的 `SettingsRow`：这一页在面板里只有三百多点宽，
/// 而 `SettingsRow` 给控件的宽度上限是 180——两者放一起会把标签挤成一条。
private struct RailSettingRow<Control: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(TM.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(TM.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, TM.cardContentHorizontal)
        .padding(.vertical, 10)
        .background(TM.fieldFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(TM.border, lineWidth: 1)
        )
    }
}

/// 环颜色的色板：与进度条配色同一套预设色，再加一个系统取色器。
private struct RailTintPicker: View {
    @Binding var rgb: UInt32

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SubscriptionQuotaColors.presets, id: \.self) { preset in
                Button { rgb = preset } label: {
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
                get: { Color(hex: rgb) },
                set: { rgb = $0.tokenMeterRGB }
            ), supportsOpacity: false)
            .labelsHidden()
            .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
