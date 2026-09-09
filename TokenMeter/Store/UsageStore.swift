import Foundation
import Observation
import os

private enum UsageStoreLogger {
    static let logger = Logger(subsystem: "com.tokenmeter.app", category: "usage")
}

enum RefreshSource: Sendable {
    case manual
    case panelOpen
    case background
}

@MainActor
@Observable
final class UsageStore {
    private(set) var subscriptions: [Subscription] = []
    private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    let settings: SettingsStore
    var autoRefreshEnabled: Bool {
        get { settings.autoRefreshEnabled }
        set { settings.autoRefreshEnabled = newValue }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let credentials = CredentialStore()
    /// 后台定时刷新循环。
    private var refreshTask: Task<Void, Never>?
    /// 当前正在执行的一段刷新（手动 / 面板 / 后台 / 单订阅共用，串行互斥）。
    private var activeRefresh: Task<Void, Never>?
    /// 订阅配置代数：订阅被删除或认证方式变更时递增，用于丢弃过期的刷新结果。
    private var configurationGeneration = 0
    /// 最近一次订阅元数据写盘失败原因；nil 表示写盘成功或尚未写盘。
    private(set) var lastPersistenceError: String?
    private(set) var lastMigrationRecoveryError: String?
    private var migrationInProgress = false
    private let alerts: AlertCoordinating
    private let metadataURLOverride: URL?

    private var metadataURL: URL {
        if let metadataURLOverride { return metadataURLOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("subscriptions.json")
    }

    init(settings: SettingsStore = SettingsStore(), alerts: AlertCoordinating? = nil, metadataURL: URL? = nil) {
        self.settings = settings
        self.alerts = alerts ?? NotificationCoordinator(settings: settings)
        self.metadataURLOverride = metadataURL
        loadSubscriptions()
        do {
            try migrationService.recoverInterruptedTransaction()
            lastMigrationRecoveryError = nil
        } catch {
            lastMigrationRecoveryError = error.localizedDescription
            UsageStoreLogger.logger.error("migration recovery failed error=\(error.localizedDescription, privacy: .public)")
        }
        loadSubscriptions()
    }

    private var migrationService: CredentialMigrationService {
        CredentialMigrationService(metadataURL: metadataURL, credentialStore: credentials)
    }

    func exportMigrationPackage(password: String) throws -> Data {
        try migrationService.exportPackage(subscriptions: subscriptions, password: password)
    }

    func exportMigrationPackageAsync(password: String) async throws -> Data {
        let service = migrationService
        let subscriptions = subscriptions
        return try await Task.detached(priority: .userInitiated) {
            try service.exportPackage(subscriptions: subscriptions, password: password)
        }.value
    }

    func prepareMigrationImport(data: Data, password: String) throws -> MigrationImportPlan {
        let payload = try migrationService.decryptPackage(data, password: password)
        return migrationService.makeImportPlan(
            payload: payload,
            localSubscriptions: subscriptions,
            localCredentials: try credentials.snapshot()
        )
    }

    func prepareMigrationImportAsync(data: Data, password: String) async throws -> MigrationImportPlan {
        let service = migrationService
        let subscriptions = subscriptions
        let localCredentials = try credentials.snapshot()
        return try await Task.detached(priority: .userInitiated) {
            let payload = try service.decryptPackage(data, password: password)
            return service.makeImportPlan(
                payload: payload,
                localSubscriptions: subscriptions,
                localCredentials: localCredentials
            )
        }.value
    }

    func commitMigrationImport(_ plan: MigrationImportPlan) async throws {
        guard !migrationInProgress else { return }
        migrationInProgress = true
        defer { migrationInProgress = false }

        // 门闩覆盖“等待 → 提交 → 内存更新 → 刷新”全程，防止任何新刷新取得旧配置。
        configurationGeneration += 1
        if let activeRefresh {
            activeRefresh.cancel()
            await activeRefresh.value
        }
        let service = migrationService
        let localSubscriptions = subscriptions
        let imported = try await Task.detached(priority: .userInitiated) {
            try service.commit(plan, localSubscriptions: localSubscriptions)
        }.value
        subscriptions = imported
        snapshots.removeAll()
        lastPersistenceError = nil
        // 只允许这次已绑定新配置的受控刷新；普通入口仍被门闩拒绝。
        refreshAll(source: .manual, allowDuringMigration: true)
    }

    func add(_ subscription: Subscription) {
        subscriptions.append(subscription)
        saveSubscriptions()
    }

    /// 手动排序：按面板拖拽/辅助功能移动的结果调整数组顺序并持久化。
    /// 显示顺序即数组顺序（新增订阅追加到末尾），不再按 createdAt 排序。
    func moveSubscriptions(fromOffsets source: IndexSet, toOffset destination: Int) {
        subscriptions.move(fromOffsets: source, toOffset: destination)
        saveSubscriptions()
    }

    func remove(_ subscription: Subscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        snapshots.removeValue(forKey: subscription.id)
        alerts.remove(subscriptionID: subscription.id)
        try? credentials.remove(for: subscription.id)
        // 取消进行中的刷新，避免网络返回后把凭证/快照写回已删除的订阅。
        configurationGeneration += 1
        cancelActiveRefresh()
        saveSubscriptions()
    }

    func rename(_ subscription: Subscription, to name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].name = name
        saveSubscriptions()
    }

    func updateAuthMethod(_ subscription: Subscription, to authMethodID: AuthMethodID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].authMethodID = authMethodID
        // 认证方式已更换（新凭证已写入）：取消进行中的刷新，
        // 防止旧凭证的刷新结果覆盖新配置。
        configurationGeneration += 1
        cancelActiveRefresh()
        saveSubscriptions()
    }

    func updateQuotaColors(_ quotaColors: [String: UInt32], for subscription: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].quotaColors = quotaColors
        saveSubscriptions()
    }

    /// 刷新单个订阅。串行执行：若已有刷新在进行则忽略（与旧行为一致）。
    func refresh(_ subscription: Subscription, source: RefreshSource = .manual) {
        launchRefresh { store in
            await store.fetch(subscription, source: source)
        }
    }

    /// 刷新全部启用的订阅，有界并发：每批最多同时刷新 `refreshBatchSize` 个订阅，
    /// 批间串行。凭证文件的 read-modify-write 已在 `CredentialStore` 内部串行化，
    /// 并发刷新不会互相覆盖。
    func refreshAll(source: RefreshSource = .manual) {
        refreshAll(source: source, allowDuringMigration: false)
    }

    private func refreshAll(source: RefreshSource, allowDuringMigration: Bool) {
        launchRefresh(allowDuringMigration: allowDuringMigration) { store in
            let enabled = store.subscriptions.filter(\.isEnabled)
            let batchSize = 3
            let batches = stride(from: 0, to: enabled.count, by: batchSize).map { start in
                Array(enabled[start..<min(start + batchSize, enabled.count)])
            }
            for batch in batches {
                if Task.isCancelled { return }
                await withTaskGroup(of: Void.self) { @MainActor group in
                    for subscription in batch {
                        group.addTask {
                            await store.fetch(subscription, source: source)
                        }
                    }
                }
            }
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // 首轮立即刷新，避免应用启动后等待一个完整刷新周期才有数据。
                if self.autoRefreshEnabled {
                    self.refreshAll(source: .background)
                }
                try? await Task.sleep(for: .seconds(self.settings.refreshInterval))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        cancelActiveRefresh()
    }

    /// 以 store 自持任务的方式启动一段刷新：任务句柄被保存，
    /// 删除订阅或切换认证方式时可通过 `cancelActiveRefresh` 取消，
    /// 阻止网络返回后把快照或凭证写回已失效的订阅。
    private func launchRefresh(allowDuringMigration: Bool = false, _ operation: @escaping @MainActor (UsageStore) async -> Void) {
        guard (!migrationInProgress || allowDuringMigration), activeRefresh == nil else { return }
        activeRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            isRefreshing = true
            defer {
                isRefreshing = false
                lastRefreshAt = .now
                activeRefresh = nil
            }
            await operation(self)
        }
    }

    private func cancelActiveRefresh() {
        activeRefresh?.cancel()
        activeRefresh = nil
    }

    private func fetch(_ subscription: Subscription, source: RefreshSource) async {
        UsageStoreLogger.logger.debug("fetch started provider=\(subscription.providerID.rawValue, privacy: .public)")
        // 记录刷新开始时的配置代数；结束时配置已变更
        // （删除/切换认证方式）则丢弃结果。
        let generation = configurationGeneration
        do {
            guard let definition = ProviderRegistry.definition(for: subscription.providerID) else {
                throw UsageProviderError.unsupported(subscription.providerID)
            }
            let snapshot = try await definition.makeUsageProvider(for: subscription).fetchUsage()
            guard isStillCurrent(subscription, generation: generation) else {
                clearStaleCredentialsIfRemoved(subscription)
                return
            }
            let previous = snapshots[subscription.id]
            snapshots[subscription.id] = snapshot
            alerts.process(previous: previous, current: snapshot, subscription: subscription, source: source)
        } catch is CancellationError {
            UsageStoreLogger.logger.debug("fetch cancelled provider=\(subscription.providerID.rawValue, privacy: .public)")
        } catch {
            guard isStillCurrent(subscription, generation: generation) else {
                clearStaleCredentialsIfRemoved(subscription)
                return
            }
            let (snapshot, state) = Self.failureSnapshot(subscription: subscription, error: error)
            let previous = snapshots[subscription.id]
            snapshots[subscription.id] = snapshot
            alerts.process(previous: previous, current: snapshot, subscription: subscription, source: source)
            UsageStoreLogger.logger.log(
                level: state == "error" ? .error : .info,
                """
                snapshot stored \
                provider=\(subscription.providerID.rawValue, privacy: .public) \
                generated=true state=\(state, privacy: .public) \
                errorClass=\(Self.errorClass(error), privacy: .public)
                """
            )
        }
    }

    /// 把刷新错误折叠成展示快照与其状态名。
    private static func failureSnapshot(
        subscription: Subscription, error: Error
    ) -> (snapshot: UsageSnapshot, state: String) {
        if case UsageProviderError.unsupported = error {
            return (.unsupported(subscription: subscription, message: error.localizedDescription), "unsupported")
        }
        if case UsageProviderError.notConfigured = error {
            return (
                UsageSnapshot(
                    subscriptionID: subscription.id,
                    providerID: subscription.providerID,
                    quotas: [], updatedAt: .now, isDemo: false,
                    errorMessage: error.localizedDescription,
                    state: .notConfigured
                ),
                "notConfigured"
            )
        }
        if case UsageProviderError.authenticationRequired = error {
            return (
                UsageSnapshot(
                    subscriptionID: subscription.id,
                    providerID: subscription.providerID,
                    quotas: [], updatedAt: .now, isDemo: false,
                    errorMessage: error.localizedDescription,
                    state: .authenticationRequired
                ),
                "authenticationRequired"
            )
        }
        return (.failure(subscription: subscription, message: error.localizedDescription), "error")
    }

    /// 配置代数未变且订阅仍存在时，刷新结果才有效。
    private func isStillCurrent(_ subscription: Subscription, generation: Int) -> Bool {
        generation == configurationGeneration && subscriptions.contains { $0.id == subscription.id }
    }

    /// 订阅已被删除时，清除刷新期间可能被 Provider 重新写回的凭证。
    /// 仅对「订阅已不存在」做清理；编辑（订阅仍在）场景由取消机制保护，
    /// 避免误删新凭证。
    private func clearStaleCredentialsIfRemoved(_ subscription: Subscription) {
        guard !subscriptions.contains(where: { $0.id == subscription.id }) else { return }
        try? credentials.remove(for: subscription.id)
        UsageStoreLogger.logger.log(
            level: .info,
            "stale credentials cleared provider=\(subscription.providerID.rawValue, privacy: .public)"
        )
    }

    private static func errorClass(_ error: Error) -> String {
        switch error {
        case UsageProviderError.httpStatus: return "httpStatus"
        case UsageProviderError.invalidJSON: return "invalidJSON"
        case UsageProviderError.requestFailed: return "requestFailed"
        case UsageProviderError.invalidResponse: return "invalidResponse"
        case UsageProviderError.authenticationRequired: return "authenticationRequired"
        case UsageProviderError.notConfigured: return "notConfigured"
        case UsageProviderError.unsupported: return "unsupported"
        default: return "other"
        }
    }

    private func loadSubscriptions() {
        guard let data = try? Data(contentsOf: metadataURL),
              let loaded = try? decoder.decode([Subscription].self, from: data) else { return }
        subscriptions = loaded
    }

    private func saveSubscriptions() {
        do {
            let directory = metadataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(subscriptions).write(to: metadataURL, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            UsageStoreLogger.logger.error(
                "subscriptions metadata write failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
