import SwiftUI

/// 条上的一个环：一条弧、中间一个供应商标记、下方一个数字。
///
/// 移植自 Pulse 的 `UsageRingView`，去掉它的 bot 动画标记、CLI 活动指示、第二圈与
/// 窗口时钟弧——那些都依赖 Pulse 自己的账号模型与本地转录扫描。
///
/// 弧从 12 点方向顺时针画，长度就是用量比例。没有比例时（只有余额的供应商、
/// 或者还没拿到读数）画一整圈很淡的轨道、中间放标记、数字放在下方。
struct RailRingView: View {
    let entry: RailEntry
    let isSelected: Bool

    private var diameter: CGFloat { RailLayout.ringDiameter }
    private var lineWidth: CGFloat { RailLayout.ringLineWidth }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(trackColor, lineWidth: lineWidth)

            if let fraction = entry.fraction {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.001))
                    .stroke(entry.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // 从 12 点方向开始顺时针。
                    .rotationEffect(.degrees(-90))
            }

            mark
        }
        .frame(width: diameter, height: diameter)
        // 选中的环稍微放大一点，与卡片里那条指向它的指针配合。
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var mark: some View {
        ProviderMarkView(
            resource: entry.markResource,
            fallbackSystemImage: entry.fallbackSystemImage,
            size: markSize,
            tint: markColor
        )
    }

    /// 标记比环小一圈，环的描边与它之间留出那道带。
    private var markSize: CGFloat { diameter * 0.5 }

    /// 拿不到读数时轨道与标记都用中性色，读起来是「还没有数」而不是「用光了」。
    private var trackColor: Color {
        entry.fraction == nil && entry.figure == nil
            ? TM.border
            : entry.tint.opacity(0.18)
    }

    private var markColor: Color {
        switch entry.state {
        case .realtime: entry.tint
        case .notConfigured, .authenticationRequired, .unsupported: TM.textTertiary
        case .error: TM.danger
        }
    }

    private var accessibilityText: String {
        var parts = [entry.title]
        if let fraction = entry.fraction {
            parts.append("已用 \(Int((fraction * 100).rounded()))%")
        } else if let figure = entry.figure {
            parts.append("剩余 \(figure)")
        }
        if entry.state != .realtime {
            parts.append(entry.state.label)
        }
        return parts.joined(separator: "，")
    }
}

/// 环下方那行数字。与环分开是因为条在窗口里是按「项」定位的，
/// 而项是环加上这行字；两者必须用同一套常量量出来，否则命中区会和绘制错位。
struct RailRingLabel: View {
    let entry: RailEntry

    var body: some View {
        Text(text)
            .font(.system(size: RailLayout.percentFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            // 预算就是 `percentTextWidth`，比它更宽的数字会被截断而不是把项撑开——
            // 项的宽度参与 AppKit 那边的窗口尺寸计算，不能由文字内容决定。
            .frame(width: RailLayout.percentTextWidth, height: RailLayout.percentTextHeight)
    }

    private var text: String {
        if let fraction = entry.fraction {
            return "\(Int((fraction * 100).rounded()))%"
        }
        return entry.figure ?? "—"
    }

    private var color: Color {
        switch entry.state {
        case .realtime: entry.fraction == nil ? TM.textSecondary : entry.tint
        case .notConfigured, .authenticationRequired, .unsupported: TM.textTertiary
        case .error: TM.danger
        }
    }
}
