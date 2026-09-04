import Foundation

struct DemoUsageProvider: UsageProvider {
    let subscription: Subscription

    func fetchUsage() async throws -> UsageSnapshot {
        try await Task.sleep(for: .milliseconds(180))
        let now = Date.now
        switch subscription.platform {
        case .deepSeek:
            return .realtime(subscription: subscription, quotas: [Quota(name: "可用余额", used: 0, limit: 28.40, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)])
        case .zhipu:
            return .realtime(subscription: subscription, quotas: [Quota(name: "GLM-4 Token", used: 7_800_000, limit: 10_000_000, resetAt: now.addingTimeInterval(5 * 86_400)), Quota(name: "今日调用次数", used: 42, limit: 100, resetAt: now.addingTimeInterval(12 * 3_600))])
        case .kimi:
            return .realtime(subscription: subscription, quotas: [
                Quota(name: "5 小时额度", used: 320_000, limit: 1_000_000, resetAt: now.addingTimeInterval(2 * 3_600), kind: .fiveHour),
                Quota(name: "每周额度", used: 1_200_000, limit: 2_000_000, resetAt: now.addingTimeInterval(5 * 86_400), kind: .weekly),
                Quota(name: "月度额度", used: 1_200_000, limit: 2_000_000, resetAt: now.addingTimeInterval(12 * 86_400), kind: .monthly)
            ])
        case .openCodeGo:
            return .realtime(subscription: subscription, quotas: [Quota(name: "订阅 Token", used: 9_300_000, limit: 10_000_000, resetAt: now.addingTimeInterval(2 * 86_400)), Quota(name: "本周请求", used: 180, limit: 500, resetAt: now.addingTimeInterval(4 * 86_400))])
        case .miniMax:
            return .realtime(subscription: subscription, quotas: [Quota(name: "MiniMax Token", used: 340_000, limit: 1_000_000, resetAt: now.addingTimeInterval(15 * 86_400)), Quota(name: "视频生成点数", used: 65, limit: 100, resetAt: now.addingTimeInterval(10 * 86_400))])
        }
    }
}
