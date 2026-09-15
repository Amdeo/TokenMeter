import Foundation
import Testing
@testable import TokenMeter

/// Kimi 紧凑双行卡：整卡接管 + 数据行内容（5 小时 → 每周 → 月，无窗口时退回余额）。
@MainActor
struct KimiCompactCardTests {
    private func subscription(authMethod: AuthMethodID = .kimiBrowserSession) -> Subscription {
        Subscription(providerID: .kimi, name: "Kimi", authMethodID: authMethod)
    }

    @Test
    func rendererTakesOverTheWholeCardOnlyInCompactStyle() {
        // 紧凑卡要图标与名称同排，走整卡接管；标准样式仍由共享外壳画头部。
        let renderer = KimiCardRenderer()
        let snapshot = renderer.sampleSnapshot(subscription: subscription())
        var compact = subscription()
        compact.cardStyle = .compact

        #expect(renderer.makeCard(
            definition: KimiProviderDefinition(), subscription: compact, snapshot: snapshot
        ) != nil)
        #expect(renderer.makeCard(
            definition: KimiProviderDefinition(), subscription: subscription(), snapshot: snapshot
        ) == nil)

        // 其他 renderer 未实现紧凑布局，也不声明该样式。
        let definition = KimiProviderDefinition()
        #expect(QuotaListCardRenderer().makeCard(definition: definition, subscription: compact, snapshot: snapshot) == nil)
        #expect(QuotaListCardRenderer().supportedStyles == [.standard])
        #expect(renderer.supportedStyles == [.standard, .compact])
    }

    @Test
    func dataLineShowsFiveHourWeeklyAndMonth() {
        let subscription = subscription()
        let snapshot = UsageSnapshot.realtime(
            subscription: subscription,
            quotas: [
                Quota(name: "5 小时额度", used: 62, limit: 100, resetAt: .now.addingTimeInterval(7200), kind: .fiveHour),
                Quota(name: "每周额度", used: 34, limit: 100, resetAt: .now.addingTimeInterval(86400), kind: .weekly)
            ],
            overallUsageRatio: 0.52, overallResetAt: .now.addingTimeInterval(86400 * 5)
        )

        let stats = KimiCompactStats.stats(snapshot: snapshot)

        #expect(stats.map(\.label) == ["5h", "周", "月"])
        // 紧凑行取整（标准卡片行内是 1 位小数）。
        #expect(stats.map(\.value) == ["62%", "34%", "52%"])
        #expect(stats.map(\.status) == [.normal, .normal, .normal])
    }

    @Test
    func dataLineFallsBackToBalanceWithoutWindows() {
        // API Key 形态：coding 接口不可用时退回平台余额，没有窗口与总使用量。
        let subscription = subscription(authMethod: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额", used: 0, limit: 3.5, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])

        let stats = KimiCompactStats.stats(snapshot: snapshot)

        #expect(stats.map(\.label) == ["余额"])
        #expect(stats.map(\.value) == ["CNY 3.50"])
    }

    @Test
    func longPressSwapsOnlyStatsThatHaveAResetTime() {
        // 长按期间：有重置时间的数值换成 d/h/m 倒计时，余额没有重置时间则保持原值。
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kimi = subscription()
        let snapshot = UsageSnapshot.realtime(
            subscription: kimi,
            quotas: [
                Quota(name: "5 小时额度", used: 62, limit: 100, resetAt: now.addingTimeInterval(11_100), kind: .fiveHour),
                Quota(name: "每周额度", used: 34, limit: 100, resetAt: now.addingTimeInterval(5 * 86_400), kind: .weekly)
            ],
            overallUsageRatio: 0.52, overallResetAt: now.addingTimeInterval(12 * 86_400)
        )

        let stats = KimiCompactStats.stats(snapshot: snapshot)

        #expect(stats.map { $0.displayValue(showsResetCountdown: true, now: now) } == ["3h5m", "5d", "12d"])
        #expect(stats.map { $0.displayValue(showsResetCountdown: false, now: now) } == ["62%", "34%", "52%"])

        let balanceSnapshot = UsageSnapshot.realtime(subscription: subscription(authMethod: .apiKey), quotas: [
            Quota(
                name: "可用余额", used: 0, limit: 3.5, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])
        let balanceStats = KimiCompactStats.stats(snapshot: balanceSnapshot)
        #expect(balanceStats.map { $0.displayValue(showsResetCountdown: true, now: now) } == ["CNY 3.50"])
        #expect(balanceStats.map { $0.displayValue(showsResetCountdown: false, now: now) } == ["CNY 3.50"])
    }

    @Test
    func monthUsesTheRatioStatusThresholds() {
        // 月数值走共享阈值：≥80% 警告、=100% 用尽。
        let subscription = subscription()
        func monthStatus(_ ratio: Double) -> QuotaStatus {
            let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [], overallUsageRatio: ratio)
            return KimiCompactStats.stats(snapshot: snapshot).first { $0.label == "月" }?.status ?? .error
        }

        #expect(monthStatus(0.79) == .normal)
        #expect(monthStatus(0.8) == .warning)
        #expect(monthStatus(1) == .exhausted)
    }
}
