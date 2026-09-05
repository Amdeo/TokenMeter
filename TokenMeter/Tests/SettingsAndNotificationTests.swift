import Foundation
import Testing
import UserNotifications
@testable import TokenMeter

@MainActor
struct SettingsAndNotificationTests {
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
    func editingAuthenticationMethodRequiresNewMatchingCredential() {
        #expect(SubscriptionCredentialRequirement.canSave(original: .manualAPIKey, selected: .manualAPIKey, apiKey: "", hasOAuthCredential: false, hasBrowserCredential: false, isImportingBrowser: false))
        #expect(!SubscriptionCredentialRequirement.canSave(original: .manualAPIKey, selected: .kimiOAuth, apiKey: "", hasOAuthCredential: false, hasBrowserCredential: false, isImportingBrowser: false))
        #expect(SubscriptionCredentialRequirement.canSave(original: .manualAPIKey, selected: .kimiOAuth, apiKey: "", hasOAuthCredential: true, hasBrowserCredential: false, isImportingBrowser: false))
        #expect(!SubscriptionCredentialRequirement.canSave(original: .manualAPIKey, selected: .kimiBrowserSession, apiKey: "", hasOAuthCredential: false, hasBrowserCredential: true, isImportingBrowser: true))
        #expect(SubscriptionCredentialRequirement.canSave(original: .manualAPIKey, selected: .kimiBrowserSession, apiKey: "", hasOAuthCredential: false, hasBrowserCredential: true, isImportingBrowser: false))
    }

    @Test
    func lowBalanceUsesDisplayedCurrencyScale() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)
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
    func lowBalanceAlertDoesNotExposeAccountOrExactBalance() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(platform: .deepSeek, name: "私人工作账号", authMethod: .manualAPIKey)
        let alert = try! #require(evaluator.evaluate(previous: nil, current: balanceSnapshot(subscription, remaining: 4.25, currency: "CNY"), subscription: subscription, source: .manual, settings: AlertSettings()).first)
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
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)
        let snapshot = UsageSnapshot(subscriptionID: subscription.id, platform: .kimi, quotas: [], updatedAt: .now, isDemo: false, errorMessage: "expired", state: .authenticationRequired)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.state == .authenticationRequired)
        #expect(decoded.state != .notConfigured)
    }

    @Test
    func lowBalanceAlertsCrossEachCurrencyThresholdOnceAndCanRecover() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let settings = AlertSettings()
        let subscription = Subscription(platform: .deepSeek, name: "DeepSeek", authMethod: .manualAPIKey)
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
        let subscription = Subscription(platform: .deepSeek, name: "DeepSeek", authMethod: .manualAPIKey)
        let snapshot = balanceSnapshot(subscription, remaining: 0, currency: "EUR")
        #expect(evaluator.evaluate(previous: nil, current: snapshot, subscription: subscription, source: .manual, settings: AlertSettings()).isEmpty)
    }

    @Test
    func disabledLowBalanceStillTracksStateUntilRecovery() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let subscription = Subscription(platform: .deepSeek, name: "DeepSeek", authMethod: .manualAPIKey)
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
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .kimiOAuth)
        let expired = UsageSnapshot(subscriptionID: subscription.id, platform: .kimi, quotas: [], updatedAt: .now, isDemo: false, errorMessage: "expired", state: .authenticationRequired)
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
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)
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
    func notificationLedgerIsolatedAndClearAllowsReminderAgain() {
        let suite = "TokenMeterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evaluator = AlertEvaluator(defaults: defaults)
        let first = Subscription(platform: .deepSeek, name: "One", authMethod: .manualAPIKey)
        let second = Subscription(platform: .deepSeek, name: "Two", authMethod: .manualAPIKey)
        let lowFirst = balanceSnapshot(first, remaining: 1, currency: "CNY")
        let lowSecond = balanceSnapshot(second, remaining: 1, currency: "CNY")
        #expect(evaluator.evaluate(previous: nil, current: lowFirst, subscription: first, source: .manual, settings: AlertSettings()).count == 1)
        #expect(evaluator.evaluate(previous: nil, current: lowSecond, subscription: second, source: .manual, settings: AlertSettings()).count == 1)
        evaluator.clear(subscriptionID: first.id)
        #expect(evaluator.evaluate(previous: nil, current: lowFirst, subscription: first, source: .manual, settings: AlertSettings()).count == 1)
    }

    private func balanceSnapshot(_ subscription: Subscription, remaining: Double, currency: String) -> UsageSnapshot {
        UsageSnapshot.realtime(subscription: subscription, quotas: [Quota(name: "余额", used: 0, limit: remaining, resetAt: nil, unit: .currency(code: currency, scale: 1), kind: .balance)])
    }
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
    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) { requestCount += 1; completion(true) }
    func getStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) { completion(.authorized) }
}
