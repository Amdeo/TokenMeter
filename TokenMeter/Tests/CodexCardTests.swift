import Foundation
import Testing
@testable import TokenMeter

// MARK: - Codex 卡片：账号级窗口 + 按模型限额 + 预付费额度

/// 参考 Pulse 的 Codex 数据形态补齐的解析与呈现：
/// `additional_rate_limits` 的按模型限额、`credits` 的预付费额度、`plan_type` 的套餐名。
struct CodexCardTests {
    private func subscription() -> Subscription {
        Subscription(providerID: .codex, name: "Codex", authMethodID: .codexDeviceOAuth)
    }

    @Test
    func parsesAdditionalModelLimitsCreditsAndPlan() throws {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("""
        {
          "plan_type": "pro",
          "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000, "reset_at": 2000000000}},
          "additional_rate_limits": [
            {"limit_name": "o3", "metered_feature": "o3", "rate_limit": {"primary_window": {"used_percent": 40, "limit_window_seconds": 604800}}}
          ],
          "credits": {"unlimited": false, "balance": "12.34"}
        }
        """.utf8))
        let snapshot = try CodexUsageProvider.parseUsage(response, subscription: subscription())

        #expect(snapshot.quotas.contains { $0.name == "5 小时额度" && $0.kind == .fiveHour })
        // 按模型限额的行名带上模型名，与账号级窗口区分开。
        #expect(snapshot.quotas.contains { $0.name == "7 天额度（o3）" && $0.kind == .weekly && $0.used == 40 })
        #expect(snapshot.quotas.contains { $0.kind == .balance && $0.limit == 12.34 })
        // 套餐名随快照带给卡片，不进额度行。
        #expect(snapshot.providerData?.string(for: ["plan"]) == "pro")
    }

    @Test
    func unlimitedCreditsDoNotAddABalanceRow() throws {
        // `unlimited` 为真表示没有额度上限：不摆一行 0 余额。
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("""
        {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":{"unlimited":true,"balance":"5"}}
        """.utf8))
        let snapshot = try CodexUsageProvider.parseUsage(response, subscription: subscription())
        #expect(!snapshot.quotas.contains { $0.kind == .balance })
    }

    @Test
    func creditsAloneAreAReading() throws {
        // 只有 credits 也算一次有效读数：余额本身就是完整读数，不该判成「没有可解析的额度窗口」。
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("""
        {"credits":{"unlimited":false,"balance":"7.50"}}
        """.utf8))
        let snapshot = try CodexUsageProvider.parseUsage(response, subscription: subscription())
        #expect(snapshot.quotas.map(\.kind) == [.balance])
        #expect(snapshot.quotas.first?.remainingText == "USD 7.50")
    }

    @Test
    func planNameMapsKnownTiersAndPassesThroughUnknown() {
        #expect(CodexUsageProvider.planName("prolite") == "Pro 5x")
        #expect(CodexUsageProvider.planName("PLUS") == "Plus")
        #expect(CodexUsageProvider.planName("future-tier") == "future-tier")
    }

    @MainActor
    @Test
    func theSummaryShowsThePlanAndTheFullestWindow() {
        let sub = subscription()
        let snapshot = UsageSnapshot.realtime(
            subscription: sub,
            quotas: [
                Quota(name: "5 小时额度", used: 10, limit: 100, resetAt: nil, kind: .fiveHour),
                Quota(name: "7 天额度", used: 90, limit: 100, resetAt: nil, kind: .weekly)
            ],
            providerData: .object(["plan": .string("plus")])
        )
        let summary = CodexCardRenderer().summary(subscription: sub, snapshot: snapshot)
        #expect(summary?.label == "Plus")
        #expect(summary?.value == "90%")
    }

    @MainActor
    @Test
    func theRendererDrawsProgressMetersAndBalanceValues() {
        let renderer = CodexCardRenderer()
        #expect(renderer.capabilities.contains(.progressMeters))
        #expect(renderer.capabilities.contains(.balanceValues))
        // 只实现标准样式：没有 makeCard 接管整卡。
        #expect(renderer.supportedStyles == [.standard])
    }

    /// 悬浮条部分：Codex 订阅（默认 `showsInRail`）在条上是一个环，环追踪最接近用尽的窗口，
    /// 悬停详情卡逐条列出账号级窗口、按模型限额与预付费额度。
    @MainActor
    @Test
    func theRailRingAndDetailCardCarryTheFullCodexReading() throws {
        let sub = subscription()
        #expect(sub.rail.showsInRail)

        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data("""
        {
          "plan_type": "pro",
          "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000}},
          "additional_rate_limits": [
            {"limit_name": "o3", "rate_limit": {"primary_window": {"used_percent": 90, "limit_window_seconds": 604800}}}
          ],
          "credits": {"unlimited": false, "balance": "12.34"}
        }
        """.utf8))
        let snapshot = try CodexUsageProvider.parseUsage(response, subscription: sub)
        let entry = RailEntryBuilder.entry(for: sub, snapshot: snapshot)

        // 环画最接近用尽的那个窗口（按模型限额的 90%），并带上 Codex 自己的单色标记。
        #expect(entry.fraction == 0.9)
        #expect(entry.markResource == CodexProviderDefinition().metadata.railMarkResource)
        // 详情卡逐条列出：账号级窗口 → 按模型限额 → 预付费额度（余额读「还剩多少」）。
        #expect(entry.rows.map(\.name) == ["5 小时额度", "7 天额度（o3）", "可用额度"])
        #expect(entry.rows.last?.kind == .balance)
        #expect(entry.rows.last?.remainingText == "USD 12.34")
    }
}
