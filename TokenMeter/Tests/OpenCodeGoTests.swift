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

        #expect(anchor.label == "每月窗口 · 9 天后重置")
        #expect(anchor.value == 0.35.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test
    func compactStyleTakesOverTheWholeCard() {
        let renderer = OpenCodeGoCardRenderer()
        let definition = OpenCodeGoProviderDefinition()
        let subscription = Subscription(providerID: .openCodeGo, name: "OpenCode Go", authMethodID: .apiKey)
        let snapshot = renderer.sampleSnapshot(subscription: subscription)
        var compact = subscription
        compact.cardStyle = .compact

        #expect(renderer.supportedStyles == [.standard, .compact])
        #expect(renderer.makeCard(definition: definition, subscription: compact, snapshot: snapshot) != nil)
        // 标准样式仍由共享外壳画头部 + 进度条正文。
        #expect(renderer.makeCard(definition: definition, subscription: subscription, snapshot: snapshot) == nil)
        // 紧凑样式只画数值不画条，但额度数值仍按订阅配色渲染，颜色目标必须还在。
        #expect(QuotaColorSettings.isAvailable(style: .compact, providerID: .openCodeGo))
    }

    @Test
    func compactDataLineShowsTheParsedWindows() {
        // 数据行取真实解析出的窗口名；百分比取整（标准卡片行内是 1 位小数）。
        let subscription = Subscription(providerID: .openCodeGo, name: "OpenCode Go", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时窗口", used: 62, limit: 100, resetAt: .now.addingTimeInterval(3_600)),
            Quota(name: "每周窗口", used: 34, limit: 100, resetAt: .now.addingTimeInterval(86_400)),
            Quota(name: "每月窗口", used: 52, limit: 100, resetAt: .now.addingTimeInterval(9 * 86_400))
        ])

        let stats = OpenCodeGoCardRenderer.stats(snapshot: snapshot)

        #expect(stats.map(\.label) == ["5h", "周", "月"])
        #expect(stats.map(\.value) == ["62%", "34%", "52%"])
        #expect(stats.map(\.status) == [.normal, .normal, .normal])
    }

    @Test
    func compactDataLineSkipsWindowsTheResponseDidNotReturn() {
        // 接口可能只返回部分窗口：缺哪个就少哪一项，标签顺序不变。
        let subscription = Subscription(providerID: .openCodeGo, name: "OpenCode Go", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "5 小时窗口", used: 18, limit: 100, resetAt: nil),
            Quota(name: "每月窗口", used: 96, limit: 100, resetAt: nil)
        ])

        let stats = OpenCodeGoCardRenderer.stats(snapshot: snapshot)

        #expect(stats.map(\.label) == ["5h", "月"])
        #expect(stats.map(\.status) == [.normal, .warning])
    }
}
