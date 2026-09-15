import Foundation
import Testing
@testable import TokenMeter

/// 外观页「卡片样式」轮播的预览区高度规则：把所有卡片样式量到的自然高度取最高那张 + 余量，
/// 让每页等高、卡片在页内居中，切换样式时预览区不跳动也不裁切卡片。
@MainActor
struct CardStylePreviewHeightTests {
    @Test
    func previewHeightWaitsForAMeasurement() {
        // 首帧还没有量到任何高度：不约束高度，预览区按卡片自然高度铺开，避免被压扁。
        #expect(CardStyleCarouselPicker.previewHeight(tallestCard: nil) == nil)
    }

    @Test
    func previewHeightAddsSlackToTheTallestCard() {
        #expect(CardStyleCarouselPicker.previewHeightPadding == 14)
        #expect(CardStyleCarouselPicker.previewHeight(tallestCard: 142) == 156)
        #expect(CardStyleCarouselPicker.previewHeight(tallestCard: 52) == 66)
    }

    @Test
    func previewHeightIgnoresUnusableMeasurements() {
        // 0 / 负数 / NaN / 无穷不是可用高度：当成没量到，否则预览区只剩 14pt，卡片会溢出。
        #expect(CardStyleCarouselPicker.previewHeight(tallestCard: 0) == nil)
        #expect(CardStyleCarouselPicker.previewHeight(tallestCard: -10) == nil)
        #expect(CardStyleCarouselPicker.previewHeight(tallestCard: .nan) == nil)
        #expect(CardStyleCarouselPicker.previewHeight(tallestCard: .infinity) == nil)
    }

    @Test
    func cardPreviewHeightsMergeEveryStyleAndPreferTheNewest() {
        var heights: [String: CGFloat] = [:]
        CardPreviewHeightKey.reduce(value: &heights) { ["standard": 142] }
        CardPreviewHeightKey.reduce(value: &heights) { ["compact": 52] }
        #expect(heights == ["standard": 142, "compact": 52])

        // 数据刷新后同一张卡变高：新值覆盖旧值，不会被上一次的高度卡住。
        CardPreviewHeightKey.reduce(value: &heights) { ["standard": 168] }
        #expect(heights["standard"] == 168)
        #expect(heights["compact"] == 52)
    }

    /// 不裁切：预览区高度容得下每一页，最高的那张上下各留余量的一半。
    @Test
    func previewHeightFitsTheTallestCardSoSwitchingStylesCannotClip() throws {
        var heights: [String: CGFloat] = [:]
        CardPreviewHeightKey.reduce(value: &heights) { ["standard": 142] }
        CardPreviewHeightKey.reduce(value: &heights) { ["compact": 52] }

        let tallest = try #require(heights.values.max())
        let preview = try #require(CardStyleCarouselPicker.previewHeight(tallestCard: tallest))
        #expect(preview == 156)
        #expect(preview - tallest == CardStyleCarouselPicker.previewHeightPadding)
        #expect(preview >= heights["compact"]!)
    }
}
