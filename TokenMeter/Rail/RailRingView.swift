import SwiftUI

/// 环怎么画：由应用级设置决定，与 `RailMetrics` 分开——那些改**尺寸**，这些只改**画法**。
struct RailRingOptions: Equatable, Sendable {
    /// 弧与数字都倒数（显示还剩多少），而不是正数（已用多少）。
    ///
    /// 只改弧长与数字；**颜色照旧按已用比例取**——「还剩多少」不改变「离用尽还有多远」，
    /// 一圈只剩一丝的环应该是一小段红的，而不是一大段绿的。
    var showsRemaining = false
    /// 环里再画一圈细弧，给次满的那个额度。
    var showsSecondRing = false
    /// 环外再画一道细弧，表示额度窗口已经过去了多少。
    var showsWindowClock = false
    /// 取数时环上跑一段弧。
    var animatesActivity = false
}

/// 条上的一个环：一条弧、中间一个供应商标记、下方一个数字。
///
/// 移植自 Pulse 的 `UsageRingView`，去掉它的 bot 动画标记与 CLI 活动指示
/// （TokenMeter 没有本地转录可扫）。
///
/// 弧从 12 点方向顺时针画，长度就是用量比例。没有比例时（只有余额的供应商、
/// 或者还没拿到读数）画一整圈很淡的轨道、中间放标记、数字放在下方。
struct RailRingView: View {
    let entry: RailEntry
    let isSelected: Bool
    var options = RailRingOptions()
    /// 正在取数。开着活动动画时环上会跑一段弧。
    var isRefreshing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    private var diameter: CGFloat { RailLayout.ringDiameter }
    private var lineWidth: CGFloat { RailLayout.ringLineWidth }

    /// 窗口时钟那圈弧：画在环**外面**，细且中性。
    ///
    /// 外面是因为里面那圈已经归用量弧了；中性是因为颜色在这个环上只说一件事，
    /// 再加一种色相就是第二套要学的颜色语言。一道细线换个半径，读起来是另一种测量，
    /// 而不像在声称什么状态。
    private static let clockWidth: CGFloat = 2
    private static let clockGap: CGFloat = 3

    /// 第二圈：画在环**里面**，比它细。
    private static let secondRingWidth: CGFloat = 2.5

    /// 弧画多少。倒数时取补集。
    private var arcFraction: Double? {
        guard let fraction = entry.fraction else { return nil }
        return options.showsRemaining ? 1 - fraction : fraction
    }

    var body: some View {
        ZStack {
            if options.showsWindowClock, let elapsed = entry.windowElapsed {
                // 用 `borderStrong` 而不是 `meterTrack`：后者是黑 8%，在条的表面上
                // 几乎看不见——一个用户主动打开、却读不出来的弧没有意义。
                arc(fraction: elapsed, color: TM.borderStrong, width: Self.clockWidth)
                    .frame(width: clockDiameter, height: clockDiameter)
            }

            Circle()
                .strokeBorder(trackColor, lineWidth: lineWidth)

            if let arcFraction {
                arc(fraction: arcFraction, color: entry.tint, width: lineWidth)
            }

            if options.showsSecondRing, let second = entry.secondFraction {
                arc(fraction: options.showsRemaining ? 1 - second : second,
                    color: entry.secondTint ?? entry.statusTint,
                    width: Self.secondRingWidth)
                    .frame(width: secondRingDiameter, height: secondRingDiameter)
            }

            // 取数时跑的那段弧。它**不是**用量：一小段，转起来，
            // 与用量弧同一个颜色，因为说的是同一件事的进行时。
            if options.animatesActivity, isRefreshing, !reduceMotion {
                Circle()
                    .trim(from: 0, to: 0.14)
                    .stroke(entry.tint.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: isSpinning
                    )
                    .onAppear { isSpinning = true }
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

    /// 一段从 12 点方向顺时针画的弧。
    private func arc(fraction: Double, color: Color, width: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: max(min(fraction, 1), 0.001))
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }

    private var clockDiameter: CGFloat { diameter + (Self.clockGap + Self.clockWidth) * 2 }
    private var secondRingDiameter: CGFloat { diameter - lineWidth - Self.secondRingWidth - 2 }

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
            let shown = options.showsRemaining ? 1 - fraction : fraction
            parts.append("\(options.showsRemaining ? "剩余" : "已用") \(Int((shown * 100).rounded()))%")
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
    /// 与环同步：倒数时数字也倒数。
    var showsRemaining = false

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
            let shown = showsRemaining ? 1 - fraction : fraction
            return "\(Int((shown * 100).rounded()))%"
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
