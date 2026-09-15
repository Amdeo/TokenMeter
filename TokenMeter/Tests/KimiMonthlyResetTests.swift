import Foundation
import Testing
@testable import TokenMeter

/// Kimi 月额度重置时间：随快照传递，并由顶部「总使用量」锚点文案消费。
@MainActor
struct KimiMonthlyResetTests {
    @Test
    func kimiSubscriptionStatsCarriesMonthlyResetTimeOnTheSnapshot() throws {
        // 月额度重置时间落在快照上（锚点文案用），而不是另起一行额度。
        let data = Data("""
        {
          "ratelimitCode7d": {"ratio": 0.0175, "resetTime": "2030-01-07T00:00:00Z"},
          "subscriptionBalance": {"amountUsedRatio": 0.9747, "expireTime": "2030-01-20T01:28:01.324990Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.overallUsageRatio == 0.9747)
        #expect(snapshot.overallResetAt != nil)
        #expect(snapshot.quotas.map(\.kind) == [.weekly])
    }

    @Test
    func kimiAnchorLabelAppendsMonthlyResetHint() throws {
        // 锚点文案形如「总使用量 · 5 天后重置」（不注入 now，只断言结构）。
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiBrowserSession)
        let snapshot = UsageSnapshot.realtime(
            subscription: subscription,
            quotas: [Quota(name: "5 小时额度", used: 1, limit: 100, resetAt: nil, kind: .fiveHour)],
            overallUsageRatio: 0.9747,
            overallResetAt: .now.addingTimeInterval(5 * 86_400)
        )

        let anchor = try #require(KimiCardRenderer().summary(subscription: subscription, snapshot: snapshot))

        #expect(anchor.value == "97.5%")
        #expect(anchor.label.hasPrefix("总使用量 · "))
        #expect(anchor.label.hasSuffix("后重置"))
        #expect(anchor.accessibilityLabel.hasPrefix("总使用量 97.5%，"))
    }
}
