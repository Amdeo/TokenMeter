import CoreGraphics
import Foundation
import SwiftUI

/// 悬浮条的尺寸常量。
///
/// 移植自 Pulse 的 `DockLayout`（`UsageDockView.swift`），去掉了它的
/// `PanelMetrics.scale` 尺寸档位：TokenMeter 只有一个尺寸，所有数字因此是定值，
/// 不必再跨 AppKit/SwiftUI 共享可变状态。
///
/// **这些数字是 AppKit 与 SwiftUI 的共同契约。** 窗口 frame 在 SwiftUI 布局之前
/// 就要算出来，所以这里的每个值都是「预算」而不是「测量值」——预算给少了不是近似，
/// 是挤压：环会被裁、命中区会和绘制错位。
enum RailLayout {
    /// 条的横向尺寸（贴左右边时是宽度，贴顶时是高度）。
    static let width: CGFloat = 64
    static let horizontalPadding: CGFloat = 10
    /// 从条的外沿量起，不是从条身平直的那一段量起：凹形外扩占掉了开头
    /// `flareHeight`，所以第一个环上方真正看得见的留白是两者之差。
    static let verticalPadding: CGFloat = 46

    static let ringDiameter: CGFloat = 36
    static let ringLineWidth: CGFloat = 4
    /// 环与它下方百分比文字之间的间距。
    static let ringToTextSpacing: CGFloat = 6
    static let percentFontSize: CGFloat = 13
    /// 百分比文字的行高与宽度。用真实字体
    /// （`.system(size: 13, weight: .medium, design: .rounded)` + `.monospacedDigit()`）
    /// 量过并向上取整。
    ///
    /// 宽度是 **40 而不是「100%」的 37**：这个框里画的不只是百分比，还有余额型供应商的
    /// 金额（见 `RailEntryBuilder.railText`），而它能产生的最宽字符串是 `99.99`，量得 39.00。
    /// 按 38 设的时候 `19.39` 正好被截成 `19…`——差 1pt，而预算给少了不是近似，是挤压。
    static let percentTextHeight: CGFloat = 16
    static let percentTextWidth: CGFloat = 40

    /// 环与它相邻项之间的间距。**基准值**：`RailMetrics` 按档位乘它。
    static let itemSpacing: CGFloat = 30

    /// 指针离开内容多远才算「走了」，以及细条命中区的额外宽容。
    static let pointerSlack: CGFloat = 8

    /// 鼠标不在条上时收成什么：贴着屏幕边缘的一道细条。
    static let collapsedWidth: CGFloat = 6
    static let collapsedHeight: CGFloat = 96
    /// 细条的跟踪区比它画出来的更宽，从内侧靠近时不必正中。
    static let collapsedHitWidth: CGFloat = 20

    /// 一个环 + 它下方百分比文字的高度。
    static var itemHeight: CGFloat { ringDiameter + ringToTextSpacing + percentTextHeight }

    /// 细条的尺寸，按 `axis` 摆放：`collapsedWidth` 贴着屏幕边缘。
    static func collapsedSize(on axis: RailEdge.Axis) -> CGSize {
        axis == .vertical
            ? CGSize(width: collapsedWidth, height: collapsedHeight)
            : CGSize(width: collapsedHeight, height: collapsedWidth)
    }

    /// 细条跟踪区的尺寸。
    static func collapsedHitSize(on axis: RailEdge.Axis) -> CGSize {
        axis == .vertical
            ? CGSize(width: collapsedHitWidth, height: collapsedHeight)
            : CGSize(width: collapsedHeight, height: collapsedHitWidth)
    }
}

/// 环与环之间的间距档位。
///
/// 只乘在 `itemSpacing` 上：环本身保持原尺寸——一个更松的条是同样的环摆得更开，
/// 不是把环拉大。
enum RailSpacing: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case roomy

    static let `default` = RailSpacing.standard

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .compact: 0.6
        case .standard: 1
        case .roomy: 1.4
        }
    }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        case .roomy: "宽松"
        }
    }
}

/// 悬浮条的配色。
///
/// 与 app 的主题无关：主题只管面板与设置窗口。条一整天悬在任意内容之上，
/// 配色由用户自己定。默认深色——实心表面只有深色才在任何壁纸上都读得清，
/// 浅色胶囊会化进浅色壁纸。
enum RailColorScheme: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    /// 跟随 app 的外观（面板与设置窗口那一套主题）。
    case followTheme

    static let `default` = RailColorScheme.dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "深色"
        case .light: "浅色"
        case .followTheme: "跟随主题"
        }
    }

    /// 钉定给悬浮条视图树的外观；跟随主题时透出环境外观。
    func pinnedColorScheme(ambient: ColorScheme) -> ColorScheme {
        switch self {
        case .dark: .dark
        case .light: .light
        case .followTheme: ambient
        }
    }
}

/// 悬浮条的尺寸预算：**由设置推出来的那一部分**。
///
/// 这些数字以前是常量，因为 TokenMeter 只有一种条。能改之后它们必须**一起**走：
/// 窗口 frame 在 SwiftUI 布局之前就要算出来，所以「几个环、间距多大、画不画百分比」
/// 决定了条多大，而命中区、环心、卡片摆放读的必须是同一份预算。
/// 散落成各算各的，就会出现「窗口按 A 算、绘制按 B 画」的错位——
/// 而预算给少了不是近似，是挤压：环会被裁、命中区会和绘制错位。
struct RailMetrics: Equatable, Sendable {
    var spacing: RailSpacing = .default
    /// 贴左右边时画不画环下方那行百分比。
    var sideShowsPercentages = true
    /// 贴顶时画不画。默认不画：横放的条就在菜单栏底下，再加一行字会把一条紧凑的胶囊变成一条横幅。
    var topShowsPercentages = false
    /// 数字画在环上方而不是下方。
    ///
    /// 只挪**位置**，不改这一项的总高——所以它影响的是环心落在项里的哪里（命中区读它），
    /// 不是条的长度。
    var labelAboveRing = false
    /// 条的收尾用整圆的端头，而不是柔化的超椭圆角。
    ///
    /// 不是「喜欢圆的东西」：环是横跨条居中的，这么圆的端头与离它最近的那个环同一条中心线，
    /// 沿着那个环绕过去——条、环、卡片于是读成同一族的曲线。整圆还有一个理由与悬浮胶囊一样：
    /// 在这个半径上圆角与凹形外扩之间没有直边，超椭圆没有东西可以缓和。
    var usesRoundEnds = false

    var itemSpacing: CGFloat { RailLayout.itemSpacing * spacing.scale }

    /// 条身内侧面两个凸角的半径。
    ///
    /// 圆端是条宽的一半（两端各一个半圆）；柔化端是 26pt，画成四阶超椭圆，
    /// 所以读起来比它的半径更紧——大约 14pt 的圆角，比它包住的 20pt 环更方。
    /// 这是 TokenMeter 一直以来的收尾样式。
    var cornerRadius: CGFloat { usesRoundEnds ? RailLayout.width / 2 : Self.softenedCornerRadius }
    /// 凹形外扩高出条身平直上沿的距离。
    ///
    /// 圆端时它等于端头自己的半径：与端头一样高、一样宽，两者在条的中线上以一个切线相遇，
    /// 于是端头是**一条** S 形曲线扫进屏幕边，而不是一个圆角接一个肩。柔化端保持 24，
    /// 比它旁边的圆角更平。
    var flareHeight: CGFloat { usesRoundEnds ? cornerRadius : Self.softenedFlareHeight }
    /// 外扩从离屏幕边缘多远开始扫。
    ///
    /// 圆端时是圆角没占掉的那整段：`cornerRadius + flareWidth` 正好等于条宽。
    /// 两种样式都落在**恰好** `width` 上——圆角与外扩共享条的上沿，这是硬约束。
    var flareWidth: CGFloat { usesRoundEnds ? RailLayout.width - cornerRadius : Self.softenedFlareWidth }
    /// 圆角的形状指数：圆端是真圆，柔化端是四阶超椭圆。
    var cornerExponent: CGFloat { usesRoundEnds ? 2 : Self.softenedExponent }

    /// 柔化端的三个数。它们与条宽互相约束（`cornerRadius + flareWidth <= width`）。
    private static let softenedCornerRadius: CGFloat = 26
    private static let softenedFlareHeight: CGFloat = 24
    private static let softenedFlareWidth: CGFloat = 38
    /// 四阶超椭圆：既让圆角保持饱满，又把它缓和进两侧的直边。
    private static let softenedExponent: CGFloat = 4

    /// 条两端各留的余量。悬浮时少一个 `flareHeight`：贴边时外扩啃掉了两端这么多，
    /// 减掉它两种状态**看得见**的呼吸感才一致。
    func endPadding(docked: Bool) -> CGFloat {
        docked ? RailLayout.verticalPadding : RailLayout.verticalPadding - flareHeight
    }

    /// 这一轴上带不带百分比文字。
    func showsPercentages(on axis: RailEdge.Axis) -> Bool {
        axis == .vertical ? sideShowsPercentages : topShowsPercentages
    }

    /// 一个环 + 它下方百分比文字的高度。
    var itemHeight: CGFloat { RailLayout.itemHeight }

    /// 单项**沿**条方向的长度。
    func itemLength(on axis: RailEdge.Axis) -> CGFloat {
        guard showsPercentages(on: axis) else { return RailLayout.ringDiameter }
        return axis == .vertical ? itemHeight : max(RailLayout.ringDiameter, RailLayout.percentTextWidth)
    }

    /// 条**横跨**自身走向的尺寸。
    ///
    /// 贴左右边时恒为 `width`：外扩与圆角共享这个量（`cornerRadius + flareWidth <= width`），
    /// 不显示文字时把条收窄会让形状自己折进去。只有条的长度会变。
    func thickness(on axis: RailEdge.Axis) -> CGFloat {
        guard axis == .horizontal, showsPercentages(on: .horizontal) else { return RailLayout.width }
        return itemHeight + RailLayout.horizontalPadding * 2
    }

    /// 给定环数时条的长度：两端余量 + 各项 + 项间距。
    func length(for itemCount: Int, on axis: RailEdge.Axis, docked: Bool = true) -> CGFloat {
        let count = CGFloat(max(itemCount, 1))
        return endPadding(docked: docked) * 2 + itemLength(on: axis) * count + itemSpacing * (count - 1)
    }

    /// 条的完整尺寸，按 `axis` 摆放。
    func size(for itemCount: Int, on axis: RailEdge.Axis, docked: Bool = true) -> CGSize {
        let along = length(for: itemCount, on: axis, docked: docked)
        let across = thickness(on: axis)
        return axis == .vertical
            ? CGSize(width: across, height: along)
            : CGSize(width: along, height: across)
    }

    /// 环心**横跨**条的位置。
    ///
    /// 项在条的厚度方向居中，而项在这一方向上恒等于环（百分比文字在环下方、
    /// 沿条方向排布，横跨方向只占环的宽度），所以这不是简单的「一半条宽」时也无妨：
    /// `thickness` 比环大是刻意的，条一直画得比内容宽。
    func ringCentreAcross(on axis: RailEdge.Axis) -> CGFloat {
        (thickness(on: axis) - RailLayout.ringDiameter) / 2 + RailLayout.ringDiameter / 2
    }

    /// 第一个环心沿条方向的位置，以及相邻两环的步长。
    func firstRingAlong(docked: Bool = true, on axis: RailEdge.Axis = .vertical) -> CGFloat {
        // 数字在上时，环心要从那一行字的下沿再往下量。
        let labelThenRing = RailLayout.percentTextHeight + RailLayout.ringToTextSpacing
        let intoVertical = labelAboveRing
            ? labelThenRing + RailLayout.ringDiameter / 2
            : RailLayout.ringDiameter / 2
        let intoItem = axis == .vertical ? intoVertical : itemLength(on: axis) / 2
        return endPadding(docked: docked) + intoItem
    }

    func ringStep(on axis: RailEdge.Axis) -> CGFloat {
        itemLength(on: axis) + itemSpacing
    }
}

/// 悬停详情卡片的尺寸常量。移植自 Pulse 的 `DetailCardLayout`。
enum RailCardLayout {
    /// 卡片宽度。**不是随便定的**：它是「一行最长的内容」量出来的预算。
    ///
    /// 一行里最长的东西是重置提示加两个金额（`13 天后刷新额度 · $18600.00 / $35094.34`，
    /// 约 228pt）。250 装不下它，最后那个数会被省略号吃掉——而那一行里最值得读的
    /// 恰恰是它。280 减去左右各 18 的内边距还剩 244，量到的最长一行放得下并留有余量。
    ///
    /// 宽度同时是窗口的横向预算（见 `RailPanelLayout.cardReach`），所以它不能跟着
    /// 内容变：窗口每换一个订阅就改尺寸，会让条在屏幕上来回弹。
    static let width: CGFloat = 280
    static let padding: CGFloat = 18
    /// 环自己的曲线：环描边的外沿。
    static let cornerRadius: CGFloat = (RailLayout.ringDiameter + RailLayout.ringLineWidth) / 2

    static let pointerWidth: CGFloat = 20
    static let pointerHeight: CGFloat = 40
    /// 指针尖端与条之间的间隙：靠近但不接触。
    static let horizontalGap: CGFloat = 8

    static let contentSpacing: CGFloat = 14
    static let rowInternalSpacing: CGFloat = 7
    static let progressBarHeight: CGFloat = 6
    static let headerHeight: CGFloat = 19
    static let footnoteHeight: CGFloat = 13

    static let titleFontSize: CGFloat = 14
    static let rowFontSize: CGFloat = 11.5
    static let messageFontSize: CGFloat = 12
    static let footnoteFontSize: CGFloat = 11
    static let headerIconSize: CGFloat = 16
    static let rowTextLineHeight: CGFloat = 14

    /// 一条额度行的高度：标题 + 进度条 + 百分比。
    static var rowHeight: CGFloat {
        rowTextLineHeight + rowInternalSpacing + progressBarHeight + rowInternalSpacing + rowTextLineHeight
    }

    /// 卡片高度的公式。窗口 frame 在 SwiftUI 布局之前就要算出来，所以这是预算。
    static func height(forWindows count: Int, footnote: Bool = false) -> CGFloat {
        padding * 2
            + headerHeight
            + CGFloat(count) * (contentSpacing + rowHeight)
            + (footnote ? contentSpacing + footnoteHeight : 0)
    }

    /// 首帧布局用的初始猜测；真实高度由视图量出来。
    static var estimatedHeight: CGFloat { height(forWindows: 2) }

    /// 窗口必须为「可能出现的最高卡片」留出的空间。
    ///
    /// 卡片比窗口高就会被齐边裁掉，那看起来像渲染 bug 而不是「没放下」。
    /// 供应商上报的额度行数不定，所以这里按比今天在屏的更多来预算。
    static var maximumHeight: CGFloat { height(forWindows: 5, footnote: true) }
}

/// 悬浮条窗口的尺寸。移植自 Pulse 的 `FloatingPanelController.Layout`。
///
/// **窗口尺寸恒定**：卡片展开时窗口不会变大。变大就会移动 SwiftUI 内容所在的
/// 坐标空间的原点，条在其中看起来就会横向弹开再滑回来——Pulse 为这个 bug 付出过代价，
/// 这里照搬它的结论：窗口一开始就留出卡片展开的空间，多出来的部分是透明的。
enum RailPanelLayout {
    /// 卡片 + 指针 + 其后的间隙，也就是卡片向任一方向展开所需的横向空间。
    static var cardReach: CGFloat {
        RailCardLayout.width + RailCardLayout.pointerWidth + RailCardLayout.horizontalGap
    }

    static func size(
        for edge: RailEdge,
        railLength: CGFloat,
        notchSize: CGSize? = nil,
        metrics: RailMetrics
    ) -> CGSize {
        switch edge.axis {
        case .vertical:
            return CGSize(
                width: cardReach + RailLayout.width,
                // 取较大者：把所有订阅都打开时的条，或可能出现的最高卡片。
                height: max(railLength, RailCardLayout.maximumHeight)
            )
        case .horizontal:
            return CGSize(
                width: max(railLength, RailCardLayout.width, notchSize?.width ?? 0),
                height: metrics.thickness(on: .horizontal)
                    + (notchSize?.height ?? 0)
                    + RailCardLayout.horizontalGap
                    + RailCardLayout.pointerWidth
                    + RailCardLayout.maximumHeight
            )
        }
    }
}
