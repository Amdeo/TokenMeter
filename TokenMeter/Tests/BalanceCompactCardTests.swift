import Foundation
import SwiftUI
import Testing
@testable import TokenMeter

/// 余额卡（DeepSeek / 中转站余额）的紧凑样式：整卡接管 + 单行布局。
///
/// 单行布局是「图标 + 名称 + 金额」，金额贴右且字号更大；卡片上没有标签参数，
/// 所以不可能再渲染出「可用余额」这类重复文案。视觉结果用 `ImageRenderer` 渲染核对，
/// 这里锁住可断言的部分：样式接管、无余额回退、高度仍由图标决定。
@MainActor
struct BalanceCompactCardTests {
    private func subscription(cardStyle: SubscriptionCardStyle = .standard) -> Subscription {
        Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey, cardStyle: cardStyle)
    }

    private func balanceQuota() -> Quota {
        Quota(
            name: "可用余额", used: 0, limit: 28.17,
            resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance
        )
    }

    private func snapshot(subscription: Subscription) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [balanceQuota()])
    }

    private func renderedHeight(_ view: some View, width: CGFloat = 302) -> CGFloat? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.nsImage?.size.height
    }

    @Test
    func rendererTakesOverTheWholeCardOnlyInCompactStyle() {
        let renderer = BalanceCardRenderer()
        let definition = DeepSeekProviderDefinition()
        let compact = subscription(cardStyle: .compact)

        #expect(renderer.makeCard(
            definition: definition, subscription: compact, snapshot: snapshot(subscription: compact)
        ) != nil)
        // 标准样式仍由共享外壳画「图标 + 名称/副标题 + 余额行」。
        #expect(renderer.makeCard(
            definition: definition, subscription: subscription(), snapshot: snapshot(subscription: subscription())
        ) == nil)
        #expect(renderer.supportedStyles == [.standard, .compact])
    }

    @Test
    func compactCardWithoutABalanceFallsBackToTheSharedShell() {
        // 没有余额额度时整卡接管会只剩图标与名称，退回标准外壳让状态行照常显示。
        let compact = subscription(cardStyle: .compact)
        let empty = UsageSnapshot.realtime(subscription: compact, quotas: [])
        #expect(BalanceCardRenderer().makeCard(
            definition: DeepSeekProviderDefinition(), subscription: compact, snapshot: empty
        ) == nil)
    }

    @Test
    func compactBalanceCardIsAsTallAsTheTwoLineCompactCard() throws {
        // 单行余额卡与两行紧凑卡同高：两种布局的高度都由 30pt 图标决定，
        // 切换卡片样式不会改变行高，面板高度因此不跳。
        let compact = subscription(cardStyle: .compact)
        let quota = balanceQuota()
        let definition = DeepSeekProviderDefinition()

        let oneLine = try #require(renderedHeight(
            CompactBalanceCard(definition: definition, subscription: compact, quota: quota)
        ))
        let twoLine = try #require(renderedHeight(
            CompactUsageCard(definition: definition, subscription: compact, stats: [
                CompactUsageStat(
                    label: "余额", value: quota.remainingText,
                    source: .quota(quota), status: quota.status, resetAt: nil
                )
            ])
        ))

        #expect(CompactBalanceCard.iconSize == CompactUsageCard.iconSize)
        #expect(abs(oneLine - CompactBalanceCard.iconSize) < 0.5)
        #expect(abs(oneLine - twoLine) < 0.5)
    }
}
