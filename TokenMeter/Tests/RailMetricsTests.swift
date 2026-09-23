import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import TokenMeter

/// 悬浮条尺寸预算的回归：这些设置改的是「条长什么样」，
/// 而窗口 frame、命中区、绘制三处读的必须是**同一份**答案。
@MainActor
struct RailMetricsTests {
    // MARK: - 间距

    @Test
    func aRoomierSpacingOnlyMovesTheRingsApart() {
        let standard = RailMetrics()
        let roomy = RailMetrics(spacing: .roomy)
        let tight = RailMetrics(spacing: .compact)

        // 环本身不变：条宽与一项的长度都与间距无关。
        #expect(roomy.thickness(on: .vertical) == standard.thickness(on: .vertical))
        #expect(roomy.itemLength(on: .vertical) == standard.itemLength(on: .vertical))

        #expect(roomy.itemSpacing > standard.itemSpacing)
        #expect(tight.itemSpacing < standard.itemSpacing)
        // 只有一个环时没有「之间」，所以条一样长。
        #expect(roomy.size(for: 1, on: .vertical).height == standard.size(for: 1, on: .vertical).height)
        #expect(roomy.size(for: 4, on: .vertical).height > standard.size(for: 4, on: .vertical).height)
    }

    @Test
    func theRingStepFollowsTheSpacing() {
        for spacing in RailSpacing.allCases {
            let metrics = RailMetrics(spacing: spacing)
            #expect(metrics.ringStep(on: .vertical) == metrics.itemLength(on: .vertical) + metrics.itemSpacing)
        }
    }

    // MARK: - 百分比

    @Test
    func turningSidePercentagesOffShortensTheItemAndKeepsTheThickness() {
        let shown = RailMetrics(sideShowsPercentages: true)
        let hidden = RailMetrics(sideShowsPercentages: false)

        // 贴左右边时那行字在环下方，所以它只占**沿条**方向的长度，不占横向。
        #expect(hidden.itemLength(on: .vertical) == RailLayout.ringDiameter)
        #expect(hidden.itemLength(on: .vertical) < shown.itemLength(on: .vertical))
        #expect(hidden.thickness(on: .vertical) == shown.thickness(on: .vertical))
        #expect(hidden.size(for: 3, on: .vertical).height < shown.size(for: 3, on: .vertical).height)
    }

    @Test
    func turningTopPercentagesOnThickensTheRail() {
        let hidden = RailMetrics(topShowsPercentages: false)
        let shown = RailMetrics(topShowsPercentages: true)

        // 贴顶时那行字落在条的**横跨**方向上，所以它让条变粗，而不是变长。
        #expect(shown.thickness(on: .horizontal) > hidden.thickness(on: .horizontal))
        #expect(shown.itemLength(on: .horizontal) > hidden.itemLength(on: .horizontal))
        // 贴左右边的条不受它影响。
        #expect(shown.thickness(on: .vertical) == hidden.thickness(on: .vertical))
        #expect(shown.size(for: 3, on: .vertical) == hidden.size(for: 3, on: .vertical))
    }

    // MARK: - 数字在环上方

    @Test
    func movingTheFigureAboveTheRingMovesTheRingWithoutLengtheningTheItem() {
        let below = RailMetrics(labelAboveRing: false)
        let above = RailMetrics(labelAboveRing: true)

        // 只换位置：这一项还是那么高，条也还是那么长。
        #expect(above.itemLength(on: .vertical) == below.itemLength(on: .vertical))
        #expect(above.size(for: 3, on: .vertical) == below.size(for: 3, on: .vertical))

        // 环心往条的下方挪了整整一行字——命中区读的就是这个数。
        let shift = RailLayout.percentTextHeight + RailLayout.ringToTextSpacing
        let moved = above.firstRingAlong(docked: true, on: .vertical)
            - below.firstRingAlong(docked: true, on: .vertical)
        #expect(moved == shift)
    }

    // MARK: - 圆角端

    @Test
    func roundEndsReshapeTheEndsWithoutResizingTheRail() {
        let softened = RailMetrics(usesRoundEnds: false)
        let round = RailMetrics(usesRoundEnds: true)

        // 尺寸一个都不变：改的只是收尾的形状。
        #expect(round.size(for: 3, on: .vertical) == softened.size(for: 3, on: .vertical))
        #expect(round.endPadding(docked: true) == softened.endPadding(docked: true))

        // 圆角与外扩共享条的上沿，所以两者相加**恰好**等于条宽——两种样式都成立。
        #expect(round.cornerRadius + round.flareWidth == RailLayout.width)
        #expect(softened.cornerRadius + softened.flareWidth == RailLayout.width)

        // 圆端是条宽的一半，外扩与它一样高，角是正圆；柔化端是 26/24 与四阶超椭圆。
        #expect(round.cornerRadius == RailLayout.width / 2)
        #expect(round.flareHeight == round.cornerRadius)
        #expect(round.cornerExponent == 2)
        #expect(softened.cornerExponent == 4)

        // 悬浮时两端各少掉一个外扩；圆端的外扩更高，所以悬浮态的条比柔化端更短。
        #expect(round.endPadding(docked: false) == RailLayout.verticalPadding - round.flareHeight)
        #expect(round.endPadding(docked: false) < softened.endPadding(docked: false))
    }

    // MARK: - 细条包含关系

    /// **细条的命中区必须完全落在条的命中区之内**，对每一种预算组合都成立。
    ///
    /// 这是那个反复出现过的显示/隐藏循环的防线：细条一旦能伸到条外面，就会出现
    /// 「先把条藏起来、指针立刻又落在细条上」的点，于是再藏一次。
    /// 间距、百分比与圆角端都会改变条长，所以这条不变量必须对**每一种组合**成立，
    /// 而不是只对出厂设置。
    @Test
    func theStripStaysInsideTheRailUnderEveryBudget() {
        for spacing in RailSpacing.allCases {
            for side in [true, false] {
                for top in [true, false] {
                    for labelAbove in [true, false] {
                        for roundEnds in [true, false] {
                            let metrics = RailMetrics(
                                spacing: spacing,
                                sideShowsPercentages: side,
                                topShowsPercentages: top,
                                labelAboveRing: labelAbove,
                                usesRoundEnds: roundEnds
                            )
                            #expect(
                                RailHitArea.stripIsContainedInRail(maxEntries: 8, metrics: metrics),
                                "这套预算下细条伸出了条外：\(metrics)"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 面板尺寸

    /// 窗口必须跟着预算走：条变长了窗口也得变长，否则条会被裁。
    @Test
    func thePanelGrowsWithTheRailsBudget() {
        let tight = RailMetrics(spacing: .compact)
        let roomy = RailMetrics(spacing: .roomy)
        let tightRail = tight.size(for: 5, on: .vertical, docked: true)
        let roomyRail = roomy.size(for: 5, on: .vertical, docked: true)

        let tightPanel = RailHitArea.panelSize(
            for: .right,
            railLength: tightRail.height,
            metrics: tight
        )
        let roomyPanel = RailHitArea.panelSize(
            for: .right,
            railLength: roomyRail.height,
            metrics: roomy
        )
        #expect(roomyPanel.height > tightPanel.height)
        #expect(roomyPanel.height >= roomyRail.height)
    }
}
