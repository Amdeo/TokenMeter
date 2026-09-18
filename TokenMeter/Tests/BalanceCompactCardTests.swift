import Foundation
import Testing
@testable import TokenMeter

/// 余额卡（DeepSeek / 中转站余额）的紧凑样式：整卡接管 + 数据行只给金额、不给「可用余额」标签。
@MainActor
struct BalanceCompactCardTests {
    private func subscription(cardStyle: SubscriptionCardStyle = .standard) -> Subscription {
        Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey, cardStyle: cardStyle)
    }

    private func snapshot(subscription: Subscription) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额", used: 0, limit: 28.17,
                resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])
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
    func compactStatDropsTheLabelAndKeepsTheAmount() {
        // 金额自带币种（「CNY 28.17」），紧凑行不再重复「可用余额」这类标签。
        let quota = Quota(
            name: "可用余额", used: 0, limit: 28.17,
            resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance
        )
        let stat = CompactUsageStat.balance(quota)
        #expect(stat.label.isEmpty)
        #expect(stat.value == "CNY 28.17")
        #expect(stat.status == .normal)
        #expect(stat.resetAt == nil)
    }
}
