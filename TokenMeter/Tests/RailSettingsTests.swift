import Foundation
import SwiftUI
import UserNotifications
import Testing
@testable import TokenMeter

/// 每订阅悬浮条配置的回归：持久化兼容、条上显示哪些订阅、环追踪哪个额度、环用什么颜色。
@MainActor
struct RailSettingsTests {
    // MARK: - 持久化

    @Test
    func aSubscriptionWithoutRailSettingsDecodesToTheDefaults() throws {
        // 旧数据里没有 `rail` 键：不能因此解不出订阅，也不能让环凭空消失。
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","platform":"Kimi","name":"Kimi",
         "authMethod":"manualAPIKey","createdAt":0,"isEnabled":true}
        """.utf8)

        let subscription = try JSONDecoder().decode(Subscription.self, from: data)

        #expect(subscription.rail == SubscriptionRailSettings())
        #expect(subscription.rail.showsInRail)
        #expect(subscription.rail.trackedWindow == nil)
        #expect(subscription.rail.tintRGB == nil)
    }

    @Test
    func aPartialRailObjectKeepsTheMissingFieldsAtTheirDefaults() throws {
        // 以后新增字段时同样不能反过来咬旧数据：只有写下的那一项被读到。
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000002","platform":"Kimi","name":"Kimi",
         "authMethod":"manualAPIKey","createdAt":0,"isEnabled":true,
         "rail":{"trackedWindow":"每周额度"}}
        """.utf8)

        let subscription = try JSONDecoder().decode(Subscription.self, from: data)

        #expect(subscription.rail.showsInRail)
        #expect(subscription.rail.trackedWindow == "每周额度")
        #expect(subscription.rail.tintRGB == nil)
    }

    @Test
    func railSettingsSurviveARoundTripThroughTheSubscription() throws {
        let original = Subscription(
            providerID: .kimi,
            name: "Kimi",
            rail: SubscriptionRailSettings(
                showsInRail: false,
                trackedWindow: SubscriptionRailSettings.overallKey,
                tintRGB: 0x22C55E
            )
        )

        let decoded = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(original))

        #expect(decoded.rail == original.rail)
    }

    // MARK: - 条的配色

    /// 默认深色：条一整天悬在任意壁纸上，实心表面只有深色才到处读得清。
    /// 它也必须真的持久化——重启之后不该掉回默认。
    @Test
    func theRailsColorSchemeDefaultsToDarkAndPersists() {
        let suite = "TokenMeterTests.RailSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let makeStore = {
            SettingsStore(
                defaults: defaults,
                loginItemManager: RailSettingsLoginItemManager(),
                notificationManager: RailSettingsNotificationManager()
            )
        }

        let settings = makeStore()
        #expect(settings.railColorScheme == .dark)

        settings.railColorScheme = .light
        #expect(makeStore().railColorScheme == .light)
    }

    /// 跟随主题透出环境外观；深色与浅色直接钉。
    @Test
    func theColorSchemePinsOrPassesThrough() {
        #expect(RailColorScheme.dark.pinnedColorScheme(ambient: .light) == .dark)
        #expect(RailColorScheme.light.pinnedColorScheme(ambient: .dark) == .light)
        #expect(RailColorScheme.followTheme.pinnedColorScheme(ambient: .dark) == .dark)
        #expect(RailColorScheme.followTheme.pinnedColorScheme(ambient: .light) == .light)
    }

    // MARK: - 条上显示哪些订阅

    @Test
    func onlyTheSubscriptionsLeftOnTheRailAreBuiltIntoEntries() {
        let hidden = Subscription(providerID: .kimi, name: "隐藏", rail: SubscriptionRailSettings(showsInRail: false))
        let shown = Subscription(providerID: .deepSeek, name: "显示")
        let alsoShown = Subscription(providerID: .claude, name: "也显示")

        let railSubscriptions = RailEntryBuilder.railSubscriptions(from: [hidden, shown, alsoShown])

        // 顺序即订阅顺序：环的索引直接对应它，所以顺序不能被过滤打乱。
        #expect(railSubscriptions.map(\.id) == [shown.id, alsoShown.id])
        #expect(RailEntryBuilder.entries(subscriptions: [hidden, shown, alsoShown], snapshots: [:]).map(\.id) == [shown.id, alsoShown.id])
    }

    @Test
    func aRailWithNothingLeftOnItHasNoEntries() {
        let hidden = Subscription(providerID: .kimi, name: "隐藏", rail: SubscriptionRailSettings(showsInRail: false))

        #expect(RailEntryBuilder.railSubscriptions(from: [hidden]).isEmpty)
        #expect(RailEntryBuilder.entries(subscriptions: [hidden], snapshots: [:]).isEmpty)
    }

    // MARK: - 环追踪哪个额度

    @Test
    func theRingFollowsTheFullestWindowByDefault() {
        let entry = Self.entry(quotas: Self.windows(fiveHour: 0.2, weekly: 0.7))

        #expect(entry.fraction == 0.7)
    }

    @Test
    func aPinnedWindowOutranksTheFullestOne() {
        // 每周额度更满，但用户钉的是 5 小时那一个：钉住就是要它，不是要「更满的那个」。
        let entry = Self.entry(quotas: Self.windows(fiveHour: 0.2, weekly: 0.7), tracked: "5 小时额度")

        #expect(entry.fraction == 0.2)
    }

    @Test
    func aPinThatNoLongerMatchesFallsBackInsteadOfDrawingAnEmptyRing() {
        // 供应商换了窗口名之后，钉住的那个在这次读数里不存在。
        let entry = Self.entry(quotas: Self.windows(fiveHour: 0.2, weekly: 0.7), tracked: "每月额度")

        #expect(entry.fraction == 0.7)
    }

    @Test
    func theOverallRatioCanBePinned() {
        let subscription = Subscription(providerID: .kimi, name: "Kimi")
        let snapshot = UsageSnapshot.realtime(
            subscription: subscription,
            quotas: Self.windows(fiveHour: 0.2, weekly: 0.7),
            overallUsageRatio: 0.45
        )

        let entry = RailEntryBuilder.entry(
            for: Self.subscription(rail: SubscriptionRailSettings(trackedWindow: SubscriptionRailSettings.overallKey)),
            snapshot: snapshot
        )

        #expect(entry.fraction == 0.45)
    }

    @Test
    func aBalanceIsNotAFractionAndSoCannotBePinned() {
        // 余额画的是数字，不是弧。钉住它没有比例可画，于是退回常规规则。
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek")
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "余额", used: 10, limit: 100, resetAt: nil, unit: .currency(code: "CNY", scale: 1), kind: .balance),
            Quota(name: "每周额度", used: 70, limit: 100, resetAt: nil, kind: .weekly)
        ])

        let entry = RailEntryBuilder.entry(
            for: Self.subscription(rail: SubscriptionRailSettings(trackedWindow: "余额")),
            snapshot: snapshot
        )

        #expect(entry.fraction == 0.7)
    }

    @Test
    func aPinnedWindowThatHasNotReportedYetLeavesTheRingEmpty() {
        // 钉住的窗口在、但还没有读数：画空环，而不是改画另一个额度——
        // 那会让用户以为自己钉错了。
        let subscription = Subscription(providerID: .kimi, name: "Kimi")
        let snapshot = UsageSnapshot(
            subscriptionID: subscription.id,
            providerID: .kimi,
            quotas: [],
            updatedAt: .now,
            errorMessage: "expired",
            state: .authenticationRequired
        )

        let entry = RailEntryBuilder.entry(for: subscription, snapshot: snapshot)

        #expect(entry.fraction == nil)
    }

    // MARK: - 环的颜色

    @Test
    func aChosenColourIsWhatTheRingDraws() {
        let entry = Self.entry(quotas: Self.windows(fiveHour: 0.2, weekly: 0.7), tint: 0x22C55E)

        #expect(entry.chosenTint == Color(hex: 0x22C55E))
        #expect(entry.tint == Color(hex: 0x22C55E))
    }

    @Test
    func aSpentLimitIsStillRedWhateverColourWasChosen() {
        // **被挡住不是口味问题。** 选中的颜色是身份，红是读数，读数优先。
        let entry = Self.entry(quotas: Self.windows(fiveHour: 0.2, weekly: 1.0), tint: 0x22C55E)

        #expect(entry.status == .exhausted)
        #expect(entry.tint == TM.danger)
    }

    @Test
    func theStatusColourIsUntouchedByAChosenColour() {
        // 细条收起时的染色读的是状态色：用户给环选的颜色不该让一条一切都正常的条
        // 看起来像在报警。
        let entry = Self.entry(quotas: Self.windows(fiveHour: 0.2, weekly: 0.7), tint: 0x22C55E)

        #expect(entry.statusTint == TM.ok)
        #expect(entry.statusTint != entry.tint)
    }

    // MARK: - 草稿与落盘

    @Test
    func editingTheRailSettingsMakesTheDraftDirtyAndRevertingClearsIt() {
        let subscription = Subscription(providerID: .kimi, name: "Kimi")
        let draft = SubscriptionEditorDraft(subscription: subscription)

        #expect(!draft.isDirty)

        draft.rail.tintRGB = 0x22C55E
        #expect(draft.isDirty)

        // 改回原样就不该再拦着用户离开这一页。
        draft.rail = subscription.rail
        #expect(!draft.isDirty)
    }

    @Test
    func aNewSubscriptionIsDirtyAsSoonAsItsRailSettingsAreTouched() {
        let draft = SubscriptionEditorDraft(providerID: .kimi)

        #expect(!draft.isDirty)

        draft.rail.showsInRail = false
        #expect(draft.isDirty)
    }

    @Test
    func railSettingsAreWrittenToDiskAndComeBack() throws {
        let fixture = try RailSettingsStoreFixture()
        defer { fixture.remove() }

        let subscription = Subscription(providerID: .kimi, name: "Kimi")
        let store = fixture.makeStore()
        store.add(subscription)

        let rail = SubscriptionRailSettings(
            showsInRail: false,
            trackedWindow: "每周额度",
            tintRGB: 0xEC4899
        )
        store.updateRailSettings(rail, for: subscription)
        #expect(store.lastPersistenceError == nil)

        let reloaded = fixture.makeStore()
        #expect(reloaded.subscriptions.first?.rail == rail)
    }

    // MARK: - 第二圈与窗口时钟

    @Test
    func theSecondRingFollowsTheNextFullestLimitAndSkipsBalances() {
        let entry = Self.entry(quotas: [
            Quota(name: "5 小时额度", used: 20, limit: 100, resetAt: nil, kind: .fiveHour),
            Quota(name: "每周额度", used: 70, limit: 100, resetAt: nil, kind: .weekly),
            Quota(name: "余额", used: 900, limit: 1000, resetAt: nil,
                  unit: .currency(code: "CNY", scale: 1), kind: .balance)
        ])

        // 主弧是最满的那个；第二圈是**剩下里**最满的那个。
        #expect(entry.fraction == 0.7)
        #expect(entry.secondFraction == 0.2)
        #expect(entry.secondStatus == .normal)
    }

    @Test
    func aSingleLimitDrawsNoSecondRing() {
        // 空着一圈细弧读起来像一个坏掉的读数，而不是「只有一个额度」。
        let entry = Self.entry(quotas: [
            Quota(name: "每周额度", used: 70, limit: 100, resetAt: nil, kind: .weekly)
        ])

        #expect(entry.secondFraction == nil)
        #expect(entry.secondStatus == nil)
    }

    @Test
    func theSecondRingTakesItsOwnColour() {
        // 主弧已经用尽、次弧还很宽松：那圈细弧该是绿的，而不是跟着主弧变红。
        // 次满的那个不可能比主弧更严重（它就是剩下的里最满的），所以这一侧才是真实情形。
        let entry = Self.entry(quotas: [
            Quota(name: "每周额度", used: 100, limit: 100, resetAt: nil, kind: .weekly),
            Quota(name: "5 小时额度", used: 20, limit: 100, resetAt: nil, kind: .fiveHour)
        ])

        #expect(entry.status == .exhausted)
        #expect(entry.secondStatus == .normal)
        #expect(entry.tint == TM.danger)
        #expect(entry.secondTint == TM.ok)
    }

    @Test
    func theWindowClockCountsDownFromTheResetTime() {
        let now = Date()
        let fiveHour = Quota(
            name: "5 小时额度", used: 0, limit: 100,
            resetAt: now.addingTimeInterval(2.5 * 3600), kind: .fiveHour
        )
        let elapsed = try? #require(RailEntryBuilder.windowElapsed(of: fiveHour, now: now))
        #expect(elapsed == 0.5)

        // 已经过重置时间的额度算「刚好走完」，而不是负数。
        let overdue = Quota(name: "5 小时额度", used: 0, limit: 100,
                            resetAt: now.addingTimeInterval(-60), kind: .fiveHour)
        #expect(RailEntryBuilder.windowElapsed(of: overdue, now: now) == 1)
    }

    @Test
    func aLimitWithoutAWindowLengthDrawsNoClock() {
        // 通用额度推不出长度，画一个长度靠猜的弧比不画更糟。
        let generic = Quota(name: "每日额度", used: 10, limit: 100, resetAt: .now.addingTimeInterval(3600))
        #expect(RailEntryBuilder.windowElapsed(of: generic) == nil)

        let noReset = Quota(name: "每周额度", used: 10, limit: 100, resetAt: nil, kind: .weekly)
        #expect(RailEntryBuilder.windowElapsed(of: noReset) == nil)
    }

    @Test
    func theRingCarriesTheTrackedWindowsClock() {
        // 时钟跟的是**环画的那个**额度，不是碰巧最满的那个：
        // 钉住 5 小时（刚过一半），环画的就是它，时钟也是它的一半。
        let now = Date()
        let entry = Self.entry(
            quotas: Self.windows(
                fiveHour: 0.2,
                weekly: 0.7,
                resetAt: now.addingTimeInterval(2.5 * 3600)
            ),
            tracked: "5 小时额度"
        )

        #expect(entry.fraction == 0.2)
        let elapsed = entry.windowElapsed ?? -1
        #expect(abs(elapsed - 0.5) < 0.01)
    }

    // MARK: - 夹具

    private static func subscription(rail: SubscriptionRailSettings = SubscriptionRailSettings()) -> Subscription {
        Subscription(providerID: .kimi, name: "Kimi", rail: rail)
    }

    private static func windows(fiveHour: Double, weekly: Double, resetAt: Date? = nil) -> [Quota] {
        [
            Quota(name: "5 小时额度", used: fiveHour * 100, limit: 100, resetAt: resetAt, kind: .fiveHour),
            Quota(name: "每周额度", used: weekly * 100, limit: 100, resetAt: nil, kind: .weekly)
        ]
    }

    private static func entry(
        quotas: [Quota],
        tracked: String? = nil,
        tint: UInt32? = nil
    ) -> RailEntry {
        let subscription = subscription(
            rail: SubscriptionRailSettings(trackedWindow: tracked, tintRGB: tint)
        )
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: quotas)
        return RailEntryBuilder.entry(for: subscription, snapshot: snapshot)
    }
}

/// 订阅元数据临时目录夹具：`makeStore()` 每次都重新从磁盘加载，
/// 用于验证保存后重新加载仍生效。
@MainActor
private final class RailSettingsStoreFixture {
    private let suite = "TokenMeterTests.RailSettings.\(UUID().uuidString)"
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenMeterTests-RailSettings-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeStore() -> UsageStore {
        UsageStore(
            settings: SettingsStore(
                defaults: UserDefaults(suiteName: suite)!,
                loginItemManager: RailSettingsLoginItemManager(),
                notificationManager: RailSettingsNotificationManager()
            ),
            metadataURL: directory.appendingPathComponent("subscriptions.json")
        )
    }

    func remove() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RailSettingsLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

private final class RailSettingsNotificationManager: NotificationAuthorizationManaging, @unchecked Sendable {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        completion(.authorized)
    }
}
