import Foundation
import Testing
import UserNotifications
@testable import TokenMeter

@MainActor
private func freshPanelNavigationState() -> PanelNavigationState {
    let suite = "TokenMeterTests.PanelNavigation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return PanelNavigationState(defaults: defaults)
}

@MainActor
struct SettingsAndNotificationTests {
    @Test
    func browserSessionSiteDataMatchesExactDomainAndSubdomainsOnly() {
        #expect(BrowserSessionSiteData.matches(domain: "kimi.com", recordDisplayName: "kimi.com"))
        #expect(BrowserSessionSiteData.matches(domain: "kimi.com", recordDisplayName: "www.kimi.com"))
        #expect(BrowserSessionSiteData.matches(domain: "kimi.com", recordDisplayName: ".kimi.com"))
        #expect(BrowserSessionSiteData.matches(domain: "kimi.com", recordDisplayName: "AUTH.KIMI.COM"))
        #expect(!BrowserSessionSiteData.matches(domain: "kimi.com", recordDisplayName: "notkimi.com"))
        #expect(!BrowserSessionSiteData.matches(domain: "kimi.com", recordDisplayName: "kimi.com.evil.cn"))
        #expect(!BrowserSessionSiteData.matches(domain: "kimi.com", recordDisplayName: "ccbus.top"))
    }

    @Test
    func panelVisibilityGateFiresOncePerDisplay() {
        var gate = PanelVisibilityGate()
        let firstDisplay = gate.didReceiveDisplayEvent()
        let duplicateDisplay = gate.didReceiveDisplayEvent()
        gate.didReceiveHiddenEvent()
        let secondDisplay = gate.didReceiveDisplayEvent()
        #expect(firstDisplay)
        #expect(!duplicateDisplay)
        #expect(secondDisplay)
    }

    @Test
    func reportedAdaptiveHeightClampsToPanelBounds() {
        let navigation = freshPanelNavigationState()
        navigation.beginAdding()
        navigation.reportMeasuredHeight(PanelSize.minimumAdaptiveHeight - 1, for: .addProvider)
        #expect(navigation.panelSize.height == PanelSize.minimumAdaptiveHeight)
        navigation.reportMeasuredHeight(PanelSize.maximumAdaptiveHeight + 1, for: .addProvider)
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
    }

    @Test
    func newManualCredentialRequiresAPIKey() {
        let draft = SubscriptionEditorDraft(providerID: .deepSeek)
        #expect(!SubscriptionCredentialRequirement.canSave(
            original: nil,
            selected: .apiKey,
            flowID: .apiKey,
            draft: draft
        ))
        draft.apiKey = "replacement-key"
        #expect(SubscriptionCredentialRequirement.canSave(
            original: nil,
            selected: .apiKey,
            flowID: .apiKey,
            draft: draft
        ))
    }

    @Test
    func editingAuthenticationMethodRequiresNewMatchingCredential() {
        let draft = SubscriptionEditorDraft(providerID: .deepSeek)
        #expect(SubscriptionCredentialRequirement.canSave(
            original: .apiKey,
            selected: .apiKey,
            flowID: .apiKey,
            draft: draft
        ))
        draft.authMethodID = .kimiDeviceOAuth
        #expect(!SubscriptionCredentialRequirement.canSave(
            original: .apiKey,
            selected: .kimiDeviceOAuth,
            flowID: .deviceOAuth,
            draft: draft
        ))
        draft.oauthCredential = OAuthCredential(accessToken: "oauth", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")
        #expect(SubscriptionCredentialRequirement.canSave(
            original: .apiKey,
            selected: .kimiDeviceOAuth,
            flowID: .deviceOAuth,
            draft: draft
        ))
        draft.authMethodID = .kimiBrowserSession
        draft.browserCredential = KimiBrowserCredential(accessToken: "browser", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")
        draft.browserImportTask = Task {}
        #expect(!SubscriptionCredentialRequirement.canSave(
            original: .apiKey,
            selected: .kimiBrowserSession,
            flowID: .browserSession,
            draft: draft
        ))
        draft.cancelTasks()
        draft.browserCredential = KimiBrowserCredential(accessToken: "browser", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")
        #expect(SubscriptionCredentialRequirement.canSave(
            original: .apiKey,
            selected: .kimiBrowserSession,
            flowID: .browserSession,
            draft: draft
        ))
    }

    @Test
    func OAuthCodeStateRequiresCredentialForCompletionAndResetsOnMethodChange() {
        let draft = SubscriptionEditorDraft(providerID: .claude)
        #expect(draft.oauthCodeAuthorizationState == .idle)

        draft.oauthCodeVerifier = "verifier"
        draft.oauthCodeState = "state"
        draft.oauthCodeAuthorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
        draft.oauthStatus = "授权页面已打开"
        #expect(draft.oauthCodeAuthorizationState == .awaitingCallback)
        #expect(!SubscriptionCredentialRequirement.canSave(
            original: nil,
            selected: .claudeOAuth,
            flowID: .oauthCode,
            draft: draft
        ))

        draft.clearAuthenticationState()
        #expect(draft.oauthCodeAuthorizationState == .idle)
        #expect(draft.oauthCodeVerifier == nil)
        #expect(draft.oauthCodeState == nil)
        #expect(draft.oauthCodeAuthorizeURL == nil)
        #expect(draft.oauthStatus == nil)
    }

    @Test
    func OAuthCodeStatePreventsDuplicateExchangeAndReturnsToAwaitingOnFailure() {
        let draft = SubscriptionEditorDraft(providerID: .claude)
        draft.oauthCodeAuthorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
        #expect(draft.oauthCodeAuthorizationState == .awaitingCallback)

        draft.oauthTask = Task {}
        #expect(draft.oauthCodeAuthorizationState == .exchanging)
        draft.oauthTask?.cancel()
        draft.oauthTask = nil
        draft.oauthStatus = "授权码无效"
        #expect(draft.oauthCodeAuthorizationState == .awaitingCallback)
        #expect(draft.oauthCredential == nil)
    }

    @Test
    func lowBalanceUsesDisplayedCurrencyScale() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [Quota(name: "余额", used: 0, limit: 400, resetAt: nil, unit: .currency(code: "CNY", scale: 100), kind: .balance)])
        #expect(evaluator.evaluate(previous: nil, current: snapshot, subscription: subscription, source: .manual, settings: AlertSettings()).count == 1)
    }
    @Test
    func panelVisibilityGateResetsWhenMovingToNewVisibleWindow() {
        var gate = PanelVisibilityGate()
        let first = gate.didReceiveDisplayEvent()
        gate.didReceiveHiddenEvent()
        let second = gate.didReceiveDisplayEvent()
        let duplicate = gate.didReceiveDisplayEvent()
        #expect(first)
        #expect(second)
        #expect(!duplicate)
    }

    @Test
    func refreshingLoginItemStatusNeverMutatesSystemRegistration() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = FakeLoginItemManager()
        login.status = .enabled
        let settings = SettingsStore(defaults: defaults, loginItemManager: login, notificationManager: FakeNotificationAuthorizationManager())
        settings.refreshLoginItemStatus()
        #expect(settings.launchAtLogin)
        #expect(login.registerCount == 0)
        #expect(login.unregisterCount == 0)
    }

    @Test
    func failedLoginItemChangesDoNotAttemptOppositeOperation() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = FakeLoginItemManager()
        let settings = SettingsStore(defaults: defaults, loginItemManager: login, notificationManager: FakeNotificationAuthorizationManager())

        login.registerError = TestError.failed
        settings.setLaunchAtLogin(true)
        #expect(!settings.launchAtLogin)
        #expect(login.registerCount == 1)
        #expect(login.unregisterCount == 0)

        login.registerError = nil
        login.status = .enabled
        settings.refreshLoginItemStatus()
        login.unregisterError = TestError.failed
        settings.setLaunchAtLogin(false)
        #expect(settings.launchAtLogin)
        #expect(login.registerCount == 1)
        #expect(login.unregisterCount == 1)
    }

    @Test
    func requiresApprovalDoesNotPresentLoginItemAsEnabled() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = FakeLoginItemManager()
        login.statusAfterRegister = .requiresApproval
        let settings = SettingsStore(defaults: defaults, loginItemManager: login, notificationManager: FakeNotificationAuthorizationManager())
        settings.setLaunchAtLogin(true)
        #expect(settings.loginItemStatus == .requiresApproval)
        #expect(!settings.launchAtLogin)
        #expect(login.registerCount == 1)
    }

    @Test
    func lowBalanceAlertDoesNotExposeAccountOrExactBalance() throws {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(providerID: .deepSeek, name: "私人工作账号", authMethodID: .apiKey)
        let alert = try #require(
            evaluator.evaluate(
                previous: nil,
                current: balanceSnapshot(subscription, remaining: 4.25, currency: "CNY"),
                subscription: subscription,
                providerName: "DeepSeek",
                source: .manual,
                settings: AlertSettings()
            ).first
        )
        #expect(!alert.title.contains(subscription.name))
        #expect(!alert.body.contains(subscription.name))
        #expect(!alert.body.contains("4.25"))
        #expect(alert.body.contains("DeepSeek"))
        #expect(alert.body.contains("CNY"))
    }

    @Test
    func settingsUseDefaultsAndPersistValues() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: FakeNotificationAuthorizationManager())

        #expect(first.refreshOnOpen)
        #expect(first.autoRefreshEnabled)
        #expect(first.lowBalanceAlerts)
        #expect(first.appearanceMode == .system)
        #expect(first.cnyBalanceThreshold == 5)
        #expect(first.usdBalanceThreshold == 1)

        first.refreshOnOpen = false
        first.autoRefreshEnabled = false
        first.cnyBalanceThreshold = 8.5
        let second = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: FakeNotificationAuthorizationManager())
        #expect(!second.refreshOnOpen)
        #expect(!second.autoRefreshEnabled)
        #expect(second.cnyBalanceThreshold == 8.5)
    }

    @Test
    func appearanceModePersistsAcrossSettingsInstances() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: FakeNotificationAuthorizationManager())
        first.appearanceMode = .light
        let second = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: FakeNotificationAuthorizationManager())
        #expect(second.appearanceMode == .light)
        second.appearanceMode = .dark
        let third = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: FakeNotificationAuthorizationManager())
        #expect(third.appearanceMode == .dark)
    }

    @Test
    func appearanceModeFallsBackToSystemForInvalidRawValue() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not-a-mode", forKey: "settings.appearanceMode")
        let settings = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: FakeNotificationAuthorizationManager())
        #expect(settings.appearanceMode == .system)
    }

    @Test
    func settingsRequestNotificationAuthorizationOnlyWhenAlertTurnsOn() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = FakeNotificationAuthorizationManager()
        let settings = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: notifications)
        settings.lowBalanceAlerts = false
        settings.lowBalanceAlerts = true
        settings.lowBalanceAlerts = true
        #expect(notifications.requestCount == 1)
    }

    /// 系统拒绝注册通知时必须给出原因，而不是让按钮看起来毫无反应。
    @Test
    func notificationRefusalSurfacesReasonAndClearsAfterSuccess() async {
        let suite = "TokenMeterTests.NotificationRefusal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let notifications = FakeNotificationAuthorizationManager()
        notifications.requestError = NSError(domain: UNErrorDomain, code: 1)
        let settings = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: notifications)

        settings.requestNotificationsIfNeeded()
        await settle { settings.notificationRequestError != nil }
        #expect(settings.notificationRequestError?.isEmpty == false)

        notifications.requestError = nil
        settings.requestNotificationsIfNeeded()
        await settle { settings.notificationRequestError == nil }
        #expect(settings.notificationRequestError == nil)
    }

    /// 让 `requestNotificationsIfNeeded` 内的 MainActor 任务执行完（最多让出 50 次）。
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test
    func settingsLoginItemSuccessAndFailureRollBack() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let login = FakeLoginItemManager()
        let settings = SettingsStore(defaults: defaults, loginItemManager: login, notificationManager: FakeNotificationAuthorizationManager())
        settings.setLaunchAtLogin(true)
        settings.setLaunchAtLogin(false)
        #expect(login.registerCount == 1)
        #expect(login.unregisterCount == 1)
        #expect(!settings.launchAtLogin)

        login.registerError = TestError.failed
        settings.setLaunchAtLogin(true)
        #expect(!settings.launchAtLogin)
        #expect(settings.loginItemError != nil)
    }

    @Test
    func settingsClampNegativeThresholds() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, loginItemManager: FakeLoginItemManager(), notificationManager: FakeNotificationAuthorizationManager())
        settings.cnyBalanceThreshold = -4
        settings.usdBalanceThreshold = -1
        #expect(settings.cnyBalanceThreshold == 0)
        #expect(settings.usdBalanceThreshold == 0)
    }

    @Test
    func authenticationRequiredIsCodableAndDistinctFromNotConfigured() throws {
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let snapshot = UsageSnapshot(subscriptionID: subscription.id, providerID: .kimi, quotas: [], updatedAt: .now, isDemo: false, errorMessage: "expired", state: .authenticationRequired)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.state == .authenticationRequired)
        #expect(decoded.state != .notConfigured)
    }

}

@MainActor
struct AlertEvaluationTests {
    @Test
    func lowBalanceAlertsCrossEachCurrencyThresholdOnceAndCanRecover() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let settings = AlertSettings()
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        let lowCNY = balanceSnapshot(subscription, remaining: 4, currency: "CNY")
        let lowUSD = balanceSnapshot(subscription, remaining: 0.5, currency: "USD")
        #expect(evaluator.evaluate(previous: nil, current: lowCNY, subscription: subscription, source: .manual, settings: settings).count == 1)
        #expect(evaluator.evaluate(previous: lowCNY, current: lowCNY, subscription: subscription, source: .manual, settings: settings).isEmpty)
        #expect(evaluator.evaluate(previous: lowCNY, current: lowUSD, subscription: subscription, source: .manual, settings: settings).count == 1)
        let recovered = balanceSnapshot(subscription, remaining: 10, currency: "CNY")
        _ = evaluator.evaluate(previous: lowCNY, current: recovered, subscription: subscription, source: .manual, settings: settings)
        #expect(evaluator.evaluate(previous: recovered, current: lowCNY, subscription: subscription, source: .manual, settings: settings).count == 1)
    }

    @Test
    func lowBalanceUnknownCurrencyNeverAlerts() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        let snapshot = balanceSnapshot(subscription, remaining: 0, currency: "EUR")
        #expect(evaluator.evaluate(previous: nil, current: snapshot, subscription: subscription, source: .manual, settings: AlertSettings()).isEmpty)
    }

    @Test
    func disabledLowBalanceStillTracksStateUntilRecovery() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek", authMethodID: .apiKey)
        let low = balanceSnapshot(subscription, remaining: 1, currency: "CNY")
        var disabled = AlertSettings(); disabled.lowBalanceAlerts = false
        #expect(evaluator.evaluate(previous: nil, current: low, subscription: subscription, source: .manual, settings: disabled).isEmpty)
        _ = evaluator.evaluate(previous: nil, current: balanceSnapshot(subscription, remaining: 8, currency: "CNY"), subscription: subscription, source: .manual, settings: disabled)
        #expect(evaluator.evaluate(previous: nil, current: low, subscription: subscription, source: .manual, settings: AlertSettings()).count == 1)
    }

    @Test
    func authenticationAlertsDeduplicateAndResetAfterRealtime() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiDeviceOAuth)
        let expired = UsageSnapshot(subscriptionID: subscription.id, providerID: .kimi, quotas: [], updatedAt: .now, isDemo: false, errorMessage: "expired", state: .authenticationRequired)
        let realtime = UsageSnapshot.realtime(subscription: subscription, quotas: [])
        #expect(evaluator.evaluate(previous: nil, current: expired, subscription: subscription, source: .background, settings: AlertSettings()).count == 1)
        #expect(evaluator.evaluate(previous: expired, current: expired, subscription: subscription, source: .background, settings: AlertSettings()).isEmpty)
        _ = evaluator.evaluate(previous: expired, current: realtime, subscription: subscription, source: .background, settings: AlertSettings())
        #expect(evaluator.evaluate(previous: realtime, current: expired, subscription: subscription, source: .background, settings: AlertSettings()).count == 1)
    }

    @Test
    func serviceErrorsNeedTwoBackgroundFailuresAndCooldownThenRecover() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var clock = Date(timeIntervalSince1970: 1_000)
        let evaluator = AlertEvaluator(defaults: defaults, now: { clock })
        var settings = AlertSettings(); settings.serviceErrorAlerts = true
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let error = UsageSnapshot.failure(subscription: subscription, message: "network details")
        #expect(evaluator.evaluate(previous: nil, current: error, subscription: subscription, source: .manual, settings: settings).isEmpty)
        #expect(evaluator.evaluate(previous: error, current: error, subscription: subscription, source: .panelOpen, settings: settings).isEmpty)
        #expect(evaluator.evaluate(previous: error, current: error, subscription: subscription, source: .background, settings: settings).isEmpty)
        #expect(evaluator.evaluate(previous: error, current: error, subscription: subscription, source: .background, settings: settings).count == 1)
        #expect(evaluator.evaluate(previous: error, current: error, subscription: subscription, source: .background, settings: settings).isEmpty)
        clock.addTimeInterval(3600)
        #expect(evaluator.evaluate(previous: error, current: error, subscription: subscription, source: .background, settings: settings).count == 1)
        let realtime = UsageSnapshot.realtime(subscription: subscription, quotas: [])
        _ = evaluator.evaluate(previous: error, current: realtime, subscription: subscription, source: .background, settings: settings)
        #expect(evaluator.evaluate(previous: realtime, current: error, subscription: subscription, source: .background, settings: settings).isEmpty)
        #expect(evaluator.evaluate(previous: error, current: error, subscription: subscription, source: .background, settings: settings).count == 1)
    }

    @Test
    func sameCurrencyBalancesWithDifferentNamesKeepIndependentLedgers() {
        // Kimi 回退余额：同一订阅可同时有可用/代金券/现金三个 CNY 余额。
        // ledger 若不区分额度名，高余额窗口每次评估都会重置 low-balance 状态，
        // 导致低余额窗口重复提醒。
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let settings = AlertSettings()
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        let mixed = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额", used: 0, limit: 4, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            ),
            Quota(
                name: "代金券余额", used: 0, limit: 100, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])
        // 只有低余额的「可用余额」触发提醒；同一快照重复评估不得重复提醒。
        let firstRound = evaluator.evaluate(
            previous: nil, current: mixed, subscription: subscription,
            source: .manual, settings: settings
        )
        #expect(firstRound.count == 1)
        let secondRound = evaluator.evaluate(
            previous: mixed, current: mixed, subscription: subscription,
            source: .manual, settings: settings
        )
        #expect(secondRound.isEmpty)
        // 可用余额恢复、代金券余额跌破阈值：应各自独立发一次提醒。
        let swapped = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(
                name: "可用余额", used: 0, limit: 50, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            ),
            Quota(
                name: "代金券余额", used: 0, limit: 2, resetAt: nil,
                unit: .currency(code: "CNY", scale: 1), kind: .balance
            )
        ])
        let swappedRound = evaluator.evaluate(
            previous: mixed, current: swapped, subscription: subscription,
            source: .manual, settings: settings
        )
        #expect(swappedRound.count == 1)
    }

    @Test
    func notificationLedgerIsolatedAndClearAllowsReminderAgain() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let first = Subscription(providerID: .deepSeek, name: "One", authMethodID: .apiKey)
        let second = Subscription(providerID: .deepSeek, name: "Two", authMethodID: .apiKey)
        let lowFirst = balanceSnapshot(first, remaining: 1, currency: "CNY")
        let lowSecond = balanceSnapshot(second, remaining: 1, currency: "CNY")
        #expect(evaluator.evaluate(previous: nil, current: lowFirst, subscription: first, source: .manual, settings: AlertSettings()).count == 1)
        #expect(evaluator.evaluate(previous: nil, current: lowSecond, subscription: second, source: .manual, settings: AlertSettings()).count == 1)
        evaluator.clear(subscriptionID: first.id)
        #expect(evaluator.evaluate(previous: nil, current: lowFirst, subscription: first, source: .manual, settings: AlertSettings()).count == 1)
    }

}

private func balanceSnapshot(_ subscription: Subscription, remaining: Double, currency: String) -> UsageSnapshot {
    UsageSnapshot.realtime(subscription: subscription, quotas: [Quota(name: "余额", used: 0, limit: remaining, resetAt: nil, unit: .currency(code: currency, scale: 1), kind: .balance)])
}

private enum TestError: Error { case failed }

private final class FakeLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var status: LoginItemStatus = .notRegistered
    var registerCount = 0
    var unregisterCount = 0
    var registerError: Error?
    var unregisterError: Error?
    var statusAfterRegister: LoginItemStatus = .enabled
    var statusAfterUnregister: LoginItemStatus = .notRegistered
    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }
    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = statusAfterUnregister
    }
}

private final class FakeNotificationAuthorizationManager: NotificationAuthorizationManaging, @unchecked Sendable {
    var requestCount = 0
    /// 非 nil 时模拟系统拒绝注册（如未签名构建返回 UNErrorDomain code 1）。
    var requestError: Error?
    func requestAuthorization(completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        requestCount += 1
        if let requestError {
            completion(.failure(requestError))
        } else {
            completion(.success(true))
        }
    }
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) { completion(.authorized) }
}

@MainActor
struct PanelNavigationTests {
    @Test
    func manualOverviewHeightPersistsOnlyWhenCommitted() {
        let suite = "TokenMeterTests.PanelHeight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let navigation = PanelNavigationState(defaults: defaults)
        navigation.setUserOverviewHeight(710, persist: false)
        #expect(navigation.panelSize.height == 710)
        #expect(PanelNavigationState(defaults: defaults).panelSize == .compact)

        navigation.setUserOverviewHeight(710, persist: true)
        let restored = PanelNavigationState(defaults: defaults)
        #expect(restored.hasManualOverviewHeight)
        #expect(restored.panelSize.height == 710)
    }

    @Test
    func manualOverviewHeightIsClampedAndDoesNotDisableOtherRouteMeasurements() {
        let suite = "TokenMeterTests.PanelHeight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let navigation = PanelNavigationState(defaults: defaults)
        navigation.setUserOverviewHeight(100, persist: false)
        #expect(navigation.panelSize.height == PanelSize.minimumAdaptiveHeight)
        navigation.setUserOverviewHeight(1_000, persist: false)
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)

        navigation.reportMeasuredHeight(420, for: .overview)
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
        navigation.route = .settings
        navigation.reportMeasuredHeight(420, for: .settings)
        #expect(navigation.panelSize.height == 420)
        navigation.route = .overview
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
    }

    @Test
    func panelFrameCentersBelowAnchorWhenSpaceAllows() {
        let frame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 398, height: 420),
            screenFrame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            anchorX: 1000,
            anchorTop: 1080
        )
        #expect(frame.midX == 1000)
        #expect(frame.maxY == 1080)
    }

    @Test
    func panelFrameClampsNearScreenEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        // 图标靠近左边缘：居中位置（-179）被钳制到屏幕边距
        let leftFrame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 398, height: 420),
            screenFrame: screen,
            anchorX: 20,
            anchorTop: 780
        )
        // 图标靠近右边缘：居中位置（781）超出上限，同样钳制
        let rightFrame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 398, height: 420),
            screenFrame: screen,
            anchorX: 980,
            anchorTop: 780
        )
        #expect(leftFrame.minX == PanelFramePositioner.screenMargin)
        #expect(rightFrame.maxX == screen.maxX - PanelFramePositioner.screenMargin)
        // 纵向锚点仍保持
        #expect(leftFrame.maxY == 780)
    }

    @Test
    func panelFrameCentersNormallyWhenNotClamped() {
        // anchorX=400：居中值 201 在屏幕边距内（不触发钳制），保持居中
        let frame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 398, height: 420),
            screenFrame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            anchorX: 400,
            anchorTop: 1080
        )
        #expect(frame.midX == 400)
    }

    @Test
    func panelFrameFallsBackToScreenCenterOnNarrowScreen() {
        // 屏幕窄到连边距都容不下（maximumX < minimumX），保持原兜底：屏幕正中
        let screen = NSRect(x: 0, y: 0, width: 300, height: 600)
        let frame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 398, height: 420),
            screenFrame: screen,
            anchorX: 150,
            anchorTop: 580
        )
        #expect(frame.minX == screen.midX - 398 / 2)
        #expect(frame.maxY == 580)
    }

    @Test
    func panelFrameKeepsTopEdgeWhileHeightChanges() {
        let shortFrame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 398, height: 320),
            screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 900),
            anchorX: 900,
            anchorTop: 870
        )
        let tallFrame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 398, height: 680),
            screenFrame: NSRect(x: 0, y: 0, width: 1200, height: 900),
            anchorX: 900,
            anchorTop: 870
        )
        #expect(shortFrame.maxY == tallFrame.maxY)
        #expect(shortFrame.midX == tallFrame.midX)
    }

    @Test
    func panelFrameClampsBottomToScreenMargin() {
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = PanelFramePositioner.frame(
            contentSize: NSSize(width: 340, height: 300),
            screenFrame: screen,
            anchorX: 400,
            anchorTop: 100
        )
        #expect(frame.minY == PanelFramePositioner.screenMargin)
    }

    @Test
    func panelUsesCompactWidthForEveryRoute() {
        let navigation = freshPanelNavigationState()
        #expect(navigation.panelSize == .compact)
        navigation.beginAdding()
        #expect(navigation.panelSize == .compact)
        navigation.selectProvider(.kimi)
        #expect(navigation.panelSize == .compact)
        navigation.returnToOverview()
        navigation.route = .settings
        #expect(navigation.panelSize == .compact)
    }

    @Test
    func adaptivePanelHeightClampsAndIgnoresOtherRoutes() {
        let navigation = freshPanelNavigationState()
        navigation.beginAdding()
        #expect(navigation.panelSize == .compact)
        navigation.reportMeasuredHeight(100, for: .addProvider)
        #expect(navigation.panelSize.height == PanelSize.minimumAdaptiveHeight)
        navigation.reportMeasuredHeight(900, for: .addProvider)
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
        navigation.reportMeasuredHeight(500, for: .settings)
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
        navigation.route = .settings
        // 自适应路由保持当前高度直到新页面测量（不再强制回 compact）
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
        navigation.reportMeasuredHeight(400, for: .addProvider)
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
    }

    @Test
    func adaptivePanelMeasurementPreservesFixedWidthAndDeduplicatesTolerance() {
        let navigation = freshPanelNavigationState()
        navigation.route = .addProvider
        navigation.reportMeasuredHeight(400, for: .addProvider)
        #expect(navigation.panelSize.width == 340)
        let measured = navigation.panelSize
        navigation.reportMeasuredHeight(400.5, for: .addProvider)
        #expect(navigation.panelSize == measured)
        navigation.reportMeasuredHeight(402, for: .addProvider)
        #expect(navigation.panelSize.height == 402)
    }
    @Test
    func overviewRouteGrowsWithSubscriptionContent() {
        // 概览页随订阅列表增高：上报内容高度，钳制到最小/最大区间内
        let navigation = freshPanelNavigationState()
        navigation.route = .overview
        navigation.reportMeasuredHeight(PanelSize.minimumAdaptiveHeight - 1, for: .overview)
        #expect(navigation.panelSize.height == PanelSize.minimumAdaptiveHeight)
        navigation.reportMeasuredHeight(420, for: .overview)
        #expect(navigation.panelSize.height == 420)
        navigation.reportMeasuredHeight(PanelSize.maximumAdaptiveHeight + 1, for: .overview)
        #expect(navigation.panelSize.height == PanelSize.maximumAdaptiveHeight)
    }

    @Test
    func subscriptionListCapKeepsOverviewBoundedBelowPanelMaximum() {
        // 列表滚动上限为正且低于全局面板最大高度：概览最多长到上限+固定 chrome
        #expect(PanelLayoutMetrics.subscriptionListMaxHeight > 0)
        #expect(PanelLayoutMetrics.subscriptionListMaxHeight < PanelSize.maximumAdaptiveHeight)
        // 内容远超列表上限时，面板高度依然被全局钳制在最大高度内
        let navigation = freshPanelNavigationState()
        navigation.route = .overview
        navigation.reportMeasuredHeight(
            PanelLayoutMetrics.subscriptionListMaxHeight + PanelLayoutMetrics.rootVerticalChrome + 200,
            for: .overview
        )
        #expect(navigation.panelSize.height <= PanelSize.maximumAdaptiveHeight)
    }

    @Test
    func addingSelectionCreatesCleanDraftAndConfigurationRoute() {
        let navigation = freshPanelNavigationState()
        navigation.beginAdding()
        #expect(navigation.draft == nil)
        #expect(navigation.route == .addProvider)

        navigation.selectProvider(.kimi)
        let draft = navigation.draft
        #expect(draft?.providerID == .kimi)
        #expect(draft?.isDirty == false)
        #expect(navigation.route == .addConfiguration)
        if case .addConfiguration = navigation.content(for: []) {
        } else { Issue.record("Provider selection did not resolve to add configuration") }
    }

    @Test
    func editingFromCardCreatesDraftAndResolvesConfigurationRoute() {
        let navigation = freshPanelNavigationState()
        let subscription = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .apiKey)
        navigation.beginEditingConfiguration(subscription)
        #expect(navigation.draft != nil)
        #expect(navigation.route == .editConfiguration(subscription.id))
        if case .editConfiguration(let draft, let resolved) = navigation.content(for: [subscription]) {
            #expect(draft.original?.id == subscription.id)
            #expect(resolved.id == subscription.id)
            #expect(!draft.isDirty)
        } else { Issue.record("Edit configuration route did not resolve") }
    }

    @Test
    func invalidRouteStatesRecoverWithoutCreatingAddConfiguration() {
        let navigation = freshPanelNavigationState()
        navigation.route = .addConfiguration
        #expect(isRecovery(navigation.content(for: [])))
        navigation.route = .editConfiguration(UUID())
        #expect(isRecovery(navigation.content(for: [])))
    }

    @Test
    func editorDraftDirtyStateTracksEveryEditableInputAndReturnsToBaseline() {
        let subscription = Subscription(providerID: .kimi, name: "Original", authMethodID: .apiKey)
        let draft = SubscriptionEditorDraft(subscription: subscription)
        #expect(!draft.isDirty)
        draft.name = "Renamed"
        #expect(draft.isDirty)
        draft.name = "Original"
        #expect(!draft.isDirty)
        draft.providerID = .deepSeek
        #expect(draft.isDirty)
        draft.providerID = .kimi
        #expect(!draft.isDirty)
        draft.apiKey = "new-key"
        #expect(draft.isDirty)
        draft.apiKey = ""
        #expect(!draft.isDirty)
        draft.authMethodID = .kimiDeviceOAuth
        #expect(draft.isDirty)
        draft.authMethodID = .apiKey
        #expect(!draft.isDirty)
        draft.oauthCredential = testOAuthCredential
        #expect(draft.isDirty)
        draft.oauthCredential = nil
        draft.browserCredential = testBrowserCredential
        #expect(draft.isDirty)
        draft.browserCredential = nil
        draft.oauthTask = Task {}
        #expect(draft.isDirty)
        draft.cancelTasks()
        #expect(!draft.isDirty)
        draft.browserImportTask = Task {}
        #expect(draft.isDirty)
        draft.cancelTasks()
        #expect(!draft.isDirty)
    }

    @Test
    func newEditorDraftStartsCleanAndBecomesDirtyForInputs() {
        let draft = SubscriptionEditorDraft(providerID: .kimi)
        #expect(!draft.isDirty)
        draft.name = "New subscription"
        #expect(draft.isDirty)
        draft.name = ""
        #expect(!draft.isDirty)
        draft.apiKey = "key"
        #expect(draft.isDirty)
    }

    @Test
    func leavingBrowserAuthenticationCancelsAndClearsImportTask() {
        let draft = SubscriptionEditorDraft(providerID: .kimi)
        let originalGeneration = draft.browserImportSessionID
        draft.browserImportTask = Task {}
        draft.browserCredential = KimiBrowserCredential(accessToken: "browser", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")

        draft.leaveBrowserAuthentication()

        #expect(draft.browserImportTask == nil)
        #expect(draft.browserCredential == nil)
        #expect(draft.browserImportSessionID != originalGeneration)
        #expect(!draft.isDirty)
    }
    @Test
    func returnToOverviewClearsDraftAndInvalidatesTasks() throws {
        let navigation = freshPanelNavigationState()
        navigation.beginAdding()
        navigation.selectProvider(.deepSeek)
        let draft = try #require(navigation.draft)
        let generation = draft.oauthSessionID
        navigation.returnToOverview()
        #expect(navigation.draft == nil)
        #expect(navigation.route == .overview)
        #expect(draft.oauthSessionID != generation)
    }

    private var testOAuthCredential: OAuthCredential {
        OAuthCredential(accessToken: "oauth", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")
    }

    private var testBrowserCredential: KimiBrowserCredential {
        KimiBrowserCredential(accessToken: "browser", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer")
    }

    private func isRecovery(_ content: PanelNavigationState.Content) -> Bool {
        if case .recovery = content { return true }
        return false
    }
}
