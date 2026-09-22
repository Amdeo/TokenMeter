import AppKit
import SwiftUI
import Testing
@testable import TokenMeter

/// 悬浮条上环标签的回归：余额短格式的取值，以及标签预算必须装得下它。
@MainActor
struct RailEntryTests {
    // MARK: - 余额短格式

    @Test
    func aSmallBalanceKeepsItsCents() {
        #expect(RailEntryBuilder.railText(for: 2.12, unit: .tokens) == "2.12")
        #expect(RailEntryBuilder.railText(for: 19.39, unit: .tokens) == "19.39")
    }

    @Test
    func aCurrencyBalanceIsShownInItsOwnUnit() {
        // `displayScale` 是除数：分表示的人民币要换成元。
        #expect(RailEntryBuilder.railText(for: 212, unit: .currency(code: "CNY", scale: 100)) == "2.12")
    }

    @Test
    func aBalanceIsTruncatedRatherThanRounded() {
        // **显示得比实际多，是错在错误的方向上。** 99.999 不能变成 100.00。
        #expect(RailEntryBuilder.railText(for: 99.999, unit: .tokens) == "99.99")
        #expect(RailEntryBuilder.railText(for: 9.999, unit: .tokens) == "9.99")
    }

    @Test
    func aBalancePastAHundredDropsItsFraction() {
        #expect(RailEntryBuilder.railText(for: 123.45, unit: .tokens) == "123")
    }

    @Test
    func aLargeBalanceTakesAKiloOrMegaSuffix() {
        #expect(RailEntryBuilder.railText(for: 1_234.56, unit: .tokens) == "1.2k")
        #expect(RailEntryBuilder.railText(for: 1_234_567, unit: .tokens) == "1.2M")
    }

    @Test
    func theKiloRolloverDoesNotInventAThousand() {
        // 999,999 截断成「999k」，而不是四舍五入出来的「1000k」。
        #expect(RailEntryBuilder.railText(for: 999_999, unit: .tokens) == "999k")
    }

    // MARK: - 预算

    /// **标签的宽度是预算，不是测量值。** 它在 AppKit 那边的窗口尺寸里已经被算进去了，
    /// 所以由文字内容决定宽度就等于让内容去改窗口——而预算给少了不是近似，是挤压：
    /// 数值会被截成「19…」，读起来像一个坏掉的读数。
    ///
    /// 这条断言是补上的：`railText` 能产生的最宽字符串是 `99.99`，量得 39.00pt，
    /// 而预算曾经是 38——正好差 1pt。
    @Test
    func theLabelBudgetFitsTheWidestFigureTheRailCanProduce() {
        // 按 `railText` 的构造，能出现的最宽形态是「两位整数 + 小数点 + 两位小数」。
        let widestFigures = [
            RailEntryBuilder.railText(for: 99.99, unit: .tokens),
            RailEntryBuilder.railText(for: 99.99, unit: .tokens),
            RailEntryBuilder.railText(for: 9.99, unit: .tokens),
            RailEntryBuilder.railText(for: 1_234.56, unit: .tokens),
        ]
        // 加上百分比本身能出现的最宽形态。
        let widestLabels = widestFigures + ["100%"]

        for label in widestLabels {
            let width = Self.renderedWidth(of: label)
            #expect(
                width <= RailLayout.percentTextWidth,
                "标签「\(label)」量得 \(width)pt，超出预算 \(RailLayout.percentTextWidth)pt"
            )
        }
    }

    @Test
    func theLabelHeightBudgetMatchesTheRenderedLine() {
        // 行高同理：给少了会让每一项溢出自己的 frame，环心与命中区随之错位。
        let height = Self.renderedHeight(of: "100%")
        #expect(height <= RailLayout.percentTextHeight)
    }

    /// 用与 `RailRingLabel` 完全相同的字体构造量一次渲染尺寸。
    private static func renderedSize(of text: String) -> CGSize {
        let probe = Text(text)
            .font(.system(size: RailLayout.percentFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        let host = NSHostingView(rootView: probe)
        host.layout()
        return host.fittingSize
    }

    private static func renderedWidth(of text: String) -> CGFloat {
        renderedSize(of: text).width
    }

    private static func renderedHeight(of text: String) -> CGFloat {
        renderedSize(of: text).height
    }
}
