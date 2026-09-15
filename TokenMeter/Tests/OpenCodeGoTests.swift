import Foundation
import Testing
@testable import TokenMeter

@MainActor
struct OpenCodeGoTests {
    /// 真实用量响应：窗口对象里的 `resetsAt` 是带毫秒的 ISO8601。
    static let usageResponseJSON = #"""
    {"usage":{
      "rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-15T12:05:59.014Z"},
      "weekly":{"status":"ok","percent":0,"resetsAt":"2026-09-21T00:00:00.014Z"},
      "monthly":{"status":"ok","percent":36,"resetsAt":"2026-10-07T02:10:31.014Z"}
    }}
    """#

    @Test
    func windowResetTimeParsesFractionalSeconds() throws {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(Self.usageResponseJSON.utf8))
        let monthly = try #require(response.findObject(for: ["monthly", "month"]))
        let resetDate = try #require(monthly.resetDate)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-10-07T02:10:31Z"))

        // 比到秒：响应里的毫秒不该影响解析结果的时间点。
        #expect(resetDate.timeIntervalSince1970.rounded() == expected.timeIntervalSince1970.rounded())
    }

    @Test
    func anchorHintCarriesMonthlyResetHint() throws {
        // 月窗口行已被锚点从正文排除，重置时间只能由顶部摘要体现。
        let subscription = Subscription(providerID: .openCodeGo, name: "OpenCode Go", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时窗口", used: 82, limit: 100, resetAt: .now.addingTimeInterval(3_600), kind: .fiveHour),
            Quota(name: "每月窗口", used: 35, limit: 100, resetAt: .now.addingTimeInterval(9 * 86_400 + 60))
        ])

        let anchor = try #require(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot))

        #expect(anchor.label == "每月窗口 · 已用 · 9 天后重置")
        #expect(anchor.value == 0.35.formatted(.percent.precision(.fractionLength(0))))
    }
}
