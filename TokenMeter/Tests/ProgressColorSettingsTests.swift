import Foundation
import Testing
import UserNotifications
@testable import TokenMeter

/// 颜色设置：能力由卡片样式与供应商卡片 renderer 各自声明，
/// 编辑流程只在卡片会画进度条或会渲染余额数值时提供入口，颜色本身仍是订阅上的同一份数据。
@MainActor
struct ProgressColorSettingsTests {
    // MARK: - 能力声明

    @Test
    func everyCardStyleDeclaresProgressMeters() {
        for style in SubscriptionCardStyle.allCases {
            #expect(style.capabilities.contains(.progressMeters), "\(style.rawValue) 缺少进度条能力声明")
        }
    }

    @Test
    func cardRenderersDeclareProgressMetersOnlyWhenTheCardDrawsThem() {
        #expect(QuotaListCardRenderer().capabilities.contains(.progressMeters))
        #expect(KimiCardRenderer().capabilities.contains(.progressMeters))
        #expect(SiyuCardRenderer().capabilities.contains(.progressMeters))
        #expect(NowCodingCardRenderer().capabilities.contains(.progressMeters))
        // 余额型与降级卡片只有一行文本，没有进度条。
        #expect(!BalanceCardRenderer().capabilities.contains(.progressMeters))
        #expect(!UnsupportedCardRenderer().capabilities.contains(.progressMeters))
    }

    @Test
    func cardRenderersDeclareBalanceValuesOnlyWhenTheCardDrawsBalanceNumbers() {
        #expect(BalanceCardRenderer().capabilities.contains(.balanceValues))
        #expect(KimiCardRenderer().capabilities.contains(.balanceValues))
        #expect(SiyuCardRenderer().capabilities.contains(.balanceValues))
        #expect(NowCodingCardRenderer().capabilities.contains(.balanceValues))
        // 列表型与降级卡片不渲染余额数值，也不展示余额颜色目标。
        #expect(!QuotaListCardRenderer().capabilities.contains(.balanceValues))
        #expect(!UnsupportedCardRenderer().capabilities.contains(.balanceValues))
    }

    @Test
    func progressMetersNeedBothStyleAndRendererCapabilities() {
        // 样式与 renderer 各自声明能力：汇总条与颜色入口都用这条判定，任一方缺席都不渲染。
        let meters = SubscriptionCardCapabilities.progressMeters
        #expect(SubscriptionCardCapabilities.renderProgressMeters(style: [meters], renderer: [meters]))
        #expect(!SubscriptionCardCapabilities.renderProgressMeters(style: [], renderer: [meters]))
        #expect(!SubscriptionCardCapabilities.renderProgressMeters(style: [meters], renderer: []))
        #expect(!SubscriptionCardCapabilities.renderProgressMeters(style: [], renderer: []))
    }

    @Test
    func headerIconHoverFeedbackHidesWhileDisabled() {
        // 悬停背景只在悬停且可用时显示；禁用（如刷新中）时不显示悬停反馈。
        #expect(HeaderIconButton.showsHoverFeedback(hovering: true, isEnabled: true))
        #expect(!HeaderIconButton.showsHoverFeedback(hovering: true, isEnabled: false))
        #expect(!HeaderIconButton.showsHoverFeedback(hovering: false, isEnabled: true))
        #expect(!HeaderIconButton.showsHoverFeedback(hovering: false, isEnabled: false))
    }

    // MARK: - 入口可用性（编辑页入口与外观页目标读的都是这一条判定）

    @Test
    func colorSettingsStayHiddenForCardsWithoutMetersOrBalanceValues() {
        // 未注册的供应商回退到 UnsupportedCardRenderer：既不画进度条也不渲染余额数值。
        let unknown = ProviderID(rawValue: "not-a-provider")
        for style in SubscriptionCardStyle.allCases {
            #expect(!QuotaColorSettings.isAvailable(style: style, providerID: unknown))
            #expect(QuotaColorSettings.targets(style: style, providerID: unknown, quotas: []).isEmpty)
        }
    }

    @Test
    func compactStyleKeepsBalanceCardsOnTheBalanceRow() {
        // 紧凑汇总条用窄判定（样式 + renderer 的进度条能力）：余额型 renderer 只有 `.balanceValues`，
        // 不得被改画成 used/limit 的假进度条；颜色入口仍可用，两个判定故意不同。
        let compact = SubscriptionCardStyle.compact.capabilities
        #expect(!SubscriptionCardCapabilities.renderProgressMeters(
            style: compact, renderer: BalanceCardRenderer().capabilities
        ))
        #expect(SubscriptionCardCapabilities.renderProgressMeters(
            style: compact, renderer: KimiCardRenderer().capabilities
        ))
        #expect(SubscriptionCardCapabilities.renderProgressMeters(
            style: compact, renderer: QuotaListCardRenderer().capabilities
        ))
        #expect(QuotaColorSettings.isAvailable(style: .compact, providerID: .deepSeek))
    }

    @Test
    func balanceCardOffersBalanceColorsWithoutProgressTargets() {
        let balance = Quota(
            name: "API 余额", used: 81.58, limit: 100, resetAt: nil,
            unit: .currency(code: "CNY", scale: 1), kind: .balance
        )

        let targets = QuotaColorSettings.targets(style: .standard, providerID: .deepSeek, quotas: [balance])

        // 余额型卡片没有进度条：逐条余额目标 + 对所有未单独配置数值生效的「默认颜色」兜底行。
        #expect(QuotaColorSettings.isAvailable(style: .standard, providerID: .deepSeek))
        #expect(targets.map(\.key) == [SubscriptionQuotaColors.nameKey("API 余额"), SubscriptionQuotaColors.genericKey])
        #expect(targets.first?.kind == .balance)
        #expect(targets.first?.name == "API 余额")
        #expect(targets.first?.previewText == "CNY 18.42")
    }

    @Test
    func balanceTargetsFallBackToTheSemanticKeyWithoutASnapshot() {
        // 新建订阅没有快照：给一个语义键兜底目标，编辑时也能先配好颜色。
        let targets = QuotaColorSettings.targets(style: .standard, providerID: .deepSeek, quotas: [])

        #expect(targets.map(\.key) == [SubscriptionQuotaColors.balanceKey, SubscriptionQuotaColors.genericKey])
        #expect(targets.first?.label == "余额数值")
        #expect(targets.first?.name == nil)
        #expect(targets.first?.kind == .balance)
    }

    @Test
    func balanceKeyResolutionChainPrefersNameThenKindThenGeneric() {
        let quota = Quota(
            name: "API 余额", used: 0, limit: 10, resetAt: nil,
            unit: .currency(code: "CNY", scale: 1), kind: .balance
        )
        #expect(SubscriptionQuotaColors.kindKey(for: .balance) == SubscriptionQuotaColors.balanceKey)

        // 名称专属 → kind.balance → generic，与进度条额度共用同一条解析链。
        #expect(SubscriptionQuotaColors.resolve([
            SubscriptionQuotaColors.nameKey(quota.name): 0x111111,
            SubscriptionQuotaColors.balanceKey: 0x222222,
            SubscriptionQuotaColors.genericKey: 0x333333
        ], quota: quota).tokenMeterRGB == 0x111111)
        #expect(SubscriptionQuotaColors.resolve([
            SubscriptionQuotaColors.balanceKey: 0x222222,
            SubscriptionQuotaColors.genericKey: 0x333333
        ], quota: quota).tokenMeterRGB == 0x222222)
        #expect(SubscriptionQuotaColors.resolve(
            [SubscriptionQuotaColors.genericKey: 0x333333], quota: quota
        ).tokenMeterRGB == 0x333333)
        // 都没配置时回退内置默认色，与展示层的“未配置显示文字主色”无关。
        #expect(SubscriptionQuotaColors.resolve([:], quota: quota).tokenMeterRGB == SubscriptionQuotaColors.defaultColor(forKind: .balance).tokenMeterRGB)

        #expect(SubscriptionQuotaColors.hasConfiguration([SubscriptionQuotaColors.balanceKey: 0x222222], name: quota.name, kind: .balance))
        #expect(SubscriptionQuotaColors.hasConfiguration([SubscriptionQuotaColors.nameKey(quota.name): 0x111111], name: quota.name, kind: .balance))
        #expect(!SubscriptionQuotaColors.hasConfiguration([:], name: quota.name, kind: .balance))
    }

    @Test
    func balanceRowColorPrefersConfiguredColorOverStatusTint() {
        // 偏低余额：未配置时维持状态警示色，配置色则始终优先（含偏低/用尽状态）。
        let low = Quota(
            name: "API 余额", used: 98, limit: 100, resetAt: nil,
            unit: .currency(code: "CNY", scale: 1), kind: .balance
        )
        #expect(low.status == .warning)
        #expect(BalanceMenuRow.valueColor(quota: low, colors: [:]).tokenMeterRGB == QuotaStatus.warning.tint.tokenMeterRGB)

        let custom: UInt32 = 0x0A0B0C
        #expect(BalanceMenuRow.valueColor(quota: low, colors: [SubscriptionQuotaColors.balanceKey: custom]).tokenMeterRGB == custom)
        #expect(BalanceMenuRow.valueColor(quota: low, colors: [SubscriptionQuotaColors.nameKey(low.name): custom]).tokenMeterRGB == custom)

        // 没有余额额度时保持次要文字色，配置色不误伤空状态。
        #expect(BalanceMenuRow.valueColor(quota: nil, colors: [SubscriptionQuotaColors.genericKey: custom]).tokenMeterRGB == TM.textSecondary.tokenMeterRGB)
    }

    @Test
    func sampleSnapshotsMatchEachRendererCardShape() {
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek")

        // 余额型：只有一条余额行，不再出现虚构的窗口额度。
        let balance = BalanceCardRenderer().sampleSnapshot(subscription: subscription)
        #expect(balance.quotas.map(\.kind) == [.balance])
        #expect(balance.overallUsageRatio == nil)

        // 列表型（默认实现）：只有两个窗口额度，没有虚构的余额行。
        let list = QuotaListCardRenderer().sampleSnapshot(subscription: subscription)
        #expect(list.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(list.overallUsageRatio == nil)

        // Kimi：两个窗口 + 总使用量聚合锚点。
        let kimi = KimiCardRenderer().sampleSnapshot(subscription: subscription)
        #expect(kimi.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(kimi.overallUsageRatio != nil)
        #expect(kimi.overallResetAt != nil)

        // Siyu / NowCoding：套餐额度 + 余额（余额供 summary 锚点）。
        let siyu = SiyuCardRenderer().sampleSnapshot(subscription: subscription)
        #expect(siyu.quotas.contains { $0.kind == .generic && $0.group != nil })
        #expect(siyu.quotas.contains { $0.kind == .balance })
        let nowCoding = NowCodingCardRenderer().sampleSnapshot(subscription: subscription)
        #expect(nowCoding.quotas.map(\.kind) == [.generic, .balance])
    }

    @Test
    func stylePreviewUsesANonAPIKeyAuthMethodSoTheOverallAnchorShows() throws {
        // Kimi 的默认认证方式是 API Key，而该形态不显示总使用量锚点；
        // 样式预览必须挑非 API Key 形态，否则预览与真实订阅卡不一致。
        let authMethod = CardStyleCarouselPicker.previewAuthMethod(for: .kimi)
        #expect(authMethod != .apiKey)

        let renderer = KimiCardRenderer()
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: authMethod)
        let snapshot = renderer.sampleSnapshot(subscription: subscription)
        let summary = try #require(renderer.summary(subscription: subscription, snapshot: snapshot))
        #expect(summary.label.hasPrefix("总使用量"))

        // 只有 API Key 的供应商保持默认选择，预览照常渲染。
        #expect(CardStyleCarouselPicker.previewAuthMethod(for: .deepSeek) == .apiKey)
    }

    @Test
    func colorSettingsTargetsSkipBalanceQuotasAndKeepGenericFallback() {
        let quotas = [
            Quota(name: "5 小时额度", used: 10, limit: 100, resetAt: nil, kind: .fiveHour),
            Quota(
                name: "API 余额", used: 20, limit: 100, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ]

        let targets = QuotaColorSettings.targets(style: .standard, providerID: .zhipu, quotas: quotas)

        let expectedKeys = [SubscriptionQuotaColors.nameKey("5 小时额度"), SubscriptionQuotaColors.genericKey]
        #expect(targets.map(\.key) == expectedKeys)
    }

    @Test
    func colorSettingsEntrySummaryReflectsConfiguredCount() {
        #expect(QuotaColorSettings.summary(for: [:]) == "使用默认配色")
        #expect(QuotaColorSettings.summary(for: [SubscriptionQuotaColors.overallKey: 0x112233]) == "已自定义 1 项")
        #expect(
            QuotaColorSettings.summary(for: [
                SubscriptionQuotaColors.overallKey: 0x112233,
                SubscriptionQuotaColors.genericKey: 0x445566
            ]) == "已自定义 2 项"
        )
    }

    // MARK: - 二级页面导航

    @Test
    func appearancePageReturnsToTheEditorItCameFrom() {
        let navigation = makeNavigation()
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        navigation.beginEditingConfiguration(subscription)

        navigation.showAppearanceSettings()
        #expect(navigation.route == .appearance)
        guard case .appearance(let draft) = navigation.content(for: [subscription]) else {
            Issue.record("外观页应携带当前草稿")
            return
        }
        #expect(draft.original?.id == subscription.id)

        // 在外观页改色后返回：仍回到同一个编辑页，草稿带着未保存的颜色。
        draft.currentQuotaColors[SubscriptionQuotaColors.overallKey] = 0x3366AA
        navigation.returnToEditor()
        #expect(navigation.route == .editConfiguration(subscription.id))
        #expect(navigation.draft?.currentQuotaColors[SubscriptionQuotaColors.overallKey] == 0x3366AA)
        #expect(navigation.draft?.isDirty == true)
    }

    @Test
    func appearancePageReturnsToTheAddFlowDraft() {
        let navigation = makeNavigation()
        navigation.beginAdding()
        navigation.selectProvider(.zhipu)

        navigation.showAppearanceSettings()
        #expect(navigation.route == .appearance)

        navigation.returnToEditor()
        #expect(navigation.route == .addConfiguration)
        #expect(navigation.draft?.original == nil)
        #expect(navigation.draft?.providerID == .zhipu)
    }

    @Test
    func appearanceRouteWithoutDraftFallsBackToRecovery() {
        let navigation = makeNavigation()
        navigation.route = .appearance

        if case .recovery = navigation.content(for: []) {} else {
            Issue.record("没有草稿时外观页应回落到恢复页")
        }
    }

    // MARK: - 旧数据兼容与保存

    @Test
    func legacyQuotaColorsDecodeEvenWhenTheCardOfferedNoColorSettings() throws {
        // 旧版本允许给余额卡片配置颜色：解码后原样保留，
        // 能力判定只影响展示与消费，不改写数据。
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000002","platform":"DeepSeek","name":"DeepSeek",
         "authMethod":"manualAPIKey","createdAt":0,"isEnabled":true,"quotaColors":{"generic":1122867}}
        """.utf8)

        let subscription = try JSONDecoder().decode(Subscription.self, from: data)

        #expect(subscription.cardStyle == .standard)
        #expect(subscription.quotaColors[.standard] == [SubscriptionQuotaColors.genericKey: 0x112233])
        #expect(subscription.currentQuotaColors == [SubscriptionQuotaColors.genericKey: 0x112233])
        // 余额型卡片现在可配余额数值颜色，旧配置也照样被消费。
        #expect(QuotaColorSettings.isAvailable(style: subscription.cardStyle, providerID: subscription.providerID))
        #expect(SubscriptionQuotaColors.hasConfiguration(subscription.currentQuotaColors, name: "API 余额", kind: .balance))
    }

    @Test
    func legacyFlatQuotaColorsMigrateToTheStandardStyle() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000003","platform":"Kimi","name":"Kimi",
         "authMethod":"manualAPIKey","createdAt":0,"isEnabled":true,
         "quotaColors":{"overall":1122867,"name.每周额度":7264290}}
        """.utf8)

        let subscription = try JSONDecoder().decode(Subscription.self, from: data)

        // 旧单一字典整体落到标准样式，一个键都不丢；其余样式保持空。
        #expect(subscription.cardStyle == .standard)
        #expect(subscription.currentQuotaColors == [
            SubscriptionQuotaColors.overallKey: 0x112233,
            SubscriptionQuotaColors.nameKey("每周额度"): 0x6ED822
        ])
        #expect(subscription.quotaColors[.compact].isEmpty)
        #expect(subscription.quotaColors[.hero].isEmpty)

        // 解码后重新编码写的是按样式隔离的新格式，旧键不会消失。
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(subscription)) as? [String: Any]
        )
        let encoded = try #require(json["quotaColors"] as? [String: Any])
        #expect(encoded.keys.sorted() == [SubscriptionCardStyle.standard.rawValue])
    }

    @Test
    func storeLoadsRealWorldLegacyFileAndMigratesColorsWithoutLosingData() throws {
        let fixture = try ColorSettingsStoreFixture()
        defer { fixture.remove() }

        // 真实旧文件形状：除了 quotaColors 仍是单一字典，其余字段都已是新格式，
        // 且部分订阅根本没有该字段。
        try Data("""
        [
          {"isEnabled":true,"authMethodID":"siyu-browser-session","providerID":"siyu",
           "quotaColors":{"name.deepseek大月卡 · 每日":15485081},"createdAt":810905858.5,
           "id":"F1481A5B-DEFB-4896-88E8-E9A8568D1E8C","cardStyle":"standard","name":"Siyu API"},
          {"isEnabled":true,"authMethodID":"manualAPIKey","providerID":"kimi","cardStyle":"compact",
           "createdAt":810905858.5,"id":"F1481A5B-DEFB-4896-88E8-E9A8568D1E8D","name":"Kimi"}
        ]
        """.utf8).write(to: fixture.directory.appendingPathComponent("subscriptions.json"))

        let store = fixture.makeStore()

        #expect(store.subscriptions.count == 2)
        let migrated = try #require(store.subscriptions.first)
        #expect(migrated.providerID == .siyu)
        #expect(migrated.cardStyle == .standard)
        #expect(migrated.currentQuotaColors == [
            SubscriptionQuotaColors.nameKey("deepseek大月卡 · 每日"): 15485081
        ])
        #expect(migrated.quotaColors[.compact].isEmpty)
        // 没有颜色字段的订阅保持空，但自己的卡片样式不受迁移影响。
        #expect(store.subscriptions[1].quotaColors.isEmpty)
        #expect(store.subscriptions[1].cardStyle == .compact)
    }

    @Test
    func stylePalettesStayIsolatedAndSurviveStyleSwitches() throws {
        var subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        subscription.currentQuotaColors = [SubscriptionQuotaColors.fiveHourKey: 0x111111]

        // 颜色页读写的是草稿当前样式的配色：切到紧凑样式不会看到也不会覆盖标准样式的颜色。
        let draft = SubscriptionEditorDraft(subscription: subscription)
        #expect(draft.currentQuotaColors == [SubscriptionQuotaColors.fiveHourKey: 0x111111])
        draft.cardStyle = .compact
        #expect(draft.currentQuotaColors.isEmpty)
        draft.currentQuotaColors = [SubscriptionQuotaColors.overallKey: 0x222222]

        // 来回切换样式：两套配色各自保留。
        draft.cardStyle = .standard
        #expect(draft.currentQuotaColors == [SubscriptionQuotaColors.fiveHourKey: 0x111111])
        draft.cardStyle = .compact
        #expect(draft.currentQuotaColors == [SubscriptionQuotaColors.overallKey: 0x222222])

        // 编码往返同样保留各样式配色。
        var configured = subscription
        configured.quotaColors[.compact] = [SubscriptionQuotaColors.overallKey: 0x222222]
        let decoded = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(configured))
        #expect(decoded.quotaColors[.standard] == [SubscriptionQuotaColors.fiveHourKey: 0x111111])
        #expect(decoded.quotaColors[.compact] == [SubscriptionQuotaColors.overallKey: 0x222222])
        #expect(decoded.quotaColors[.hero].isEmpty)
    }

    @Test
    func currentStylePaletteDrivesRenderedColors() throws {
        let quota = Quota(name: "每月窗口", used: 85, limit: 100, resetAt: nil, kind: .generic)
        var subscription = Subscription(providerID: .zhipu, name: "智谱", authMethodID: .apiKey)
        subscription.quotaColors[.standard] = [SubscriptionQuotaColors.nameKey(quota.name): 0x111111]
        subscription.quotaColors[.compact] = [SubscriptionQuotaColors.nameKey(quota.name): 0x222222]
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [quota])

        let anchor = SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot)
        #expect(anchor?.colorRGB == 0x111111)
        subscription.cardStyle = .compact
        #expect(SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot)?.colorRGB == 0x222222)
    }

    @Test
    func currentStylePaletteDrivesKimiOverallAnchor() throws {
        var subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiDeviceOAuth)
        subscription.quotaColors[.hero] = [SubscriptionQuotaColors.overallKey: 0x0A0B0C]
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [], overallUsageRatio: 0.41)

        // 标准样式没配过色：锚点用状态色；切到醒目样式后取该样式自己的配色。
        let standardAnchor = try #require(anchorOf(subscription, snapshot))
        #expect(standardAnchor.colorRGB == SubscriptionCardPresentation.ratioStatus(for: 0.41).tint.tokenMeterRGB)
        subscription.cardStyle = .hero
        #expect(anchorOf(subscription, snapshot)?.colorRGB == 0x0A0B0C)
    }

    @Test
    func editorDraftColorsPersistThroughStoreReload() throws {
        let fixture = try ColorSettingsStoreFixture()
        defer { fixture.remove() }

        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let store = fixture.makeStore()
        store.add(subscription)

        // 颜色页写的是编辑草稿；保存订阅时经 updateQuotaColors 落盘。
        let draft = SubscriptionEditorDraft(subscription: subscription)
        draft.cardStyle = .hero
        draft.currentQuotaColors = [
            SubscriptionQuotaColors.overallKey: 0x3366AA,
            SubscriptionQuotaColors.nameKey("每周额度"): 0x11BB22
        ]
        store.updateQuotaColors(draft.quotaColors, for: subscription)
        #expect(store.lastPersistenceError == nil)

        let reloaded = fixture.makeStore()
        #expect(reloaded.subscriptions.first?.quotaColors == draft.quotaColors)
        #expect(reloaded.subscriptions.first?.quotaColors[.hero] == draft.currentQuotaColors)
        #expect(reloaded.subscriptions.first?.currentQuotaColors.isEmpty == true)
    }

    @Test
    func storeKeepsLegacyColorsForCardsWhoseCapabilityIsGone() throws {
        let fixture = try ColorSettingsStoreFixture()
        defer { fixture.remove() }

        var subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        subscription.currentQuotaColors = [SubscriptionQuotaColors.genericKey: 0x112233]
        let store = fixture.makeStore()
        store.add(subscription)

        let reloaded = fixture.makeStore()
        #expect(reloaded.subscriptions.first?.currentQuotaColors == [SubscriptionQuotaColors.genericKey: 0x112233])
        #expect(reloaded.subscriptions.first?.cardStyle == .standard)
    }

    // MARK: - 夹具

    private func anchorOf(_ subscription: Subscription, _ snapshot: UsageSnapshot) -> CardSummary? {
        SubscriptionCardPresentation.anchor(subscription: subscription, snapshot: snapshot)
    }

    private func makeNavigation() -> PanelNavigationState {
        let suite = "TokenMeterTests.QuotaColorNavigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return PanelNavigationState(defaults: defaults)
    }
}

private final class ColorSettingsLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

private final class ColorSettingsNotificationManager: NotificationAuthorizationManaging, @unchecked Sendable {
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        completion(.success(true))
    }
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) { completion(.authorized) }
}

/// 订阅元数据临时目录夹具：`makeStore()` 每次都重新从磁盘加载，
/// 用于验证保存后重新加载仍生效。
@MainActor
private final class ColorSettingsStoreFixture {
    private let suite = "TokenMeterTests.QuotaColors.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenMeterTests-QuotaColors-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeStore() -> UsageStore {
        UsageStore(settings: makeSettings(), metadataURL: directory.appendingPathComponent("subscriptions.json"))
    }

    private func makeSettings() -> SettingsStore {
        SettingsStore(
            defaults: UserDefaults(suiteName: suite)!,
            loginItemManager: ColorSettingsLoginItemManager(),
            notificationManager: ColorSettingsNotificationManager()
        )
    }

    func remove() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
