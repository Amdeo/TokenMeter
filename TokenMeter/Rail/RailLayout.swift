import CoreGraphics
import Foundation

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

    /// 环与它相邻项之间的间距。
    static let itemSpacing: CGFloat = 30

    /// 条身内侧面两个凸角的半径。
    static let cornerRadius: CGFloat = 26
    /// 凹形外扩高出条身平直上沿的距离。
    static let flareHeight: CGFloat = 24
    /// 外扩从离屏幕边缘多远开始扫。
    static let flareWidth: CGFloat = 38

    /// 指针离开内容多远才算「走了」，以及细条命中区的额外宽容。
    static let pointerSlack: CGFloat = 8

    /// 鼠标不在条上时收成什么：贴着屏幕边缘的一道细条。
    static let collapsedWidth: CGFloat = 6
    static let collapsedHeight: CGFloat = 96
    /// 细条的跟踪区比它画出来的更宽，从内侧靠近时不必正中。
    static let collapsedHitWidth: CGFloat = 20

    /// 一个环 + 它下方百分比文字的高度。
    static var itemHeight: CGFloat { ringDiameter + ringToTextSpacing + percentTextHeight }

    /// 这一轴上带不带百分比文字。
    ///
    /// 贴左右边时带：文字在环下方，不额外占横向空间。贴顶时不带——横放的条就在
    /// 菜单栏底下，再加一行字会把一条紧凑的胶囊变成一条横幅。
    static func showsPercentages(on axis: RailEdge.Axis) -> Bool { axis == .vertical }

    /// 单项**沿**条方向的长度。
    static func itemLength(on axis: RailEdge.Axis) -> CGFloat {
        guard showsPercentages(on: axis) else { return ringDiameter }
        return axis == .vertical ? itemHeight : max(ringDiameter, percentTextWidth)
    }

    /// 条**横跨**自身走向的尺寸。
    ///
    /// 贴左右边时恒为 `width`：外扩与圆角共享这个量（`cornerRadius + flareWidth <= width`），
    /// 不显示文字时把条收窄会让形状自己折进去。只有条的长度会变。
    static func thickness(on axis: RailEdge.Axis) -> CGFloat {
        guard axis == .horizontal, showsPercentages(on: .horizontal) else { return width }
        return itemHeight + horizontalPadding * 2
    }

    /// 条两端各留的余量。悬浮时少一个 `flareHeight`：贴边时外扩啃掉了两端这么多，
    /// 减掉它两种状态**看得见**的呼吸感才一致。
    static func endPadding(docked: Bool) -> CGFloat {
        docked ? verticalPadding : verticalPadding - flareHeight
    }

    /// 给定环数时条的长度：两端余量 + 各项 + 项间距。
    static func length(for itemCount: Int, on axis: RailEdge.Axis, docked: Bool = true) -> CGFloat {
        let count = CGFloat(max(itemCount, 1))
        return endPadding(docked: docked) * 2 + itemLength(on: axis) * count + itemSpacing * (count - 1)
    }

    /// 条的完整尺寸，按 `axis` 摆放。
    static func size(for itemCount: Int, on axis: RailEdge.Axis, docked: Bool = true) -> CGSize {
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
    static func ringCentreAcross(on axis: RailEdge.Axis) -> CGFloat {
        (thickness(on: axis) - ringDiameter) / 2 + ringDiameter / 2
    }

    /// 第一个环心沿条方向的位置，以及相邻两环的步长。
    static func firstRingAlong(docked: Bool = true, on axis: RailEdge.Axis = .vertical) -> CGFloat {
        let intoItem = axis == .vertical ? ringDiameter / 2 : itemLength(on: axis) / 2
        return endPadding(docked: docked) + intoItem
    }

    static func ringStep(on axis: RailEdge.Axis) -> CGFloat {
        itemLength(on: axis) + itemSpacing
    }

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

/// 悬停详情卡片的尺寸常量。移植自 Pulse 的 `DetailCardLayout`。
enum RailCardLayout {
    static let width: CGFloat = 250
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

    static func size(for edge: RailEdge, railLength: CGFloat, notchSize: CGSize? = nil) -> CGSize {
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
                height: RailLayout.thickness(on: .horizontal)
                    + (notchSize?.height ?? 0)
                    + RailCardLayout.horizontalGap
                    + RailCardLayout.pointerWidth
                    + RailCardLayout.maximumHeight
            )
        }
    }
}
