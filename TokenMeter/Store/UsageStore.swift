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

typealias UsageProviderFactory = @MainActor (Subscription, CredentialStore) -> any UsageProvider

@MainActor
@Observable
final class UsageStore {
    private(set) var subscriptions: [Subscription] = []
    private(set) var snapshots: [UUID: UsageSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    private(set) var lastSuccessfulRefreshAt: Date?
    let settings: SettingsStore
    var autoRefreshEnabled: Bool {
        get { settings.autoRefreshEnabled }
        set { settings.autoRefreshEnabled = newValue }
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let credentials: CredentialStore
    private let providerFactory: UsageProviderFactory
    /// 后台定时刷新循环。
    private var refreshTask: Task<Void, Never>?
    /// 当前正在执行的一段刷新（手动 / 面板 / 后台 / 单订阅共用，串行互斥）。
    private var activeRefresh: Task<Void, Never>?
    private var activeRefreshID = UUID()
    /// 订阅配置代数：订阅被删除或认证方式变更时递增，用于丢弃过期的刷新结果。
    private var configurationGeneration = 0
    /// 最近一次订阅元数据加载或写盘失败原因；nil 表示正常。
    private(set) var lastPersistenceError: String?
    private(set) var lastMigrationRecoveryError: String?
    private var subscriptionsLoadFailed = false
    private var migrationInProgress = false
    private let alerts: AlertCoordinating
    private let metadataURLOverride: URL?

    private var metadataURL: URL {
        if let metadataURLOverride { return metadataURLOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("subscriptions.json")
    }

    init(
        settings: SettingsStore = SettingsStore(),
        alerts: AlertCoordinating? = nil,
        metadataURL: URL? = nil,
        credentialStore: CredentialStore? = nil,
        providerFactory: UsageProviderFactory? = nil
    ) {
        self.settings = settings
        self.alerts = alerts ?? NotificationCoordinator(settings: settings)
        self.metadataURLOverride = metadataURL
        self.credentials = credentialStore ?? CredentialStore(fileURL: metadataURL?
            .deletingLastPathComponent()
            .appendingPathComponent("credentials.json") ?? Self.defaultCredentialURL)
        self.providerFactory = providerFactory ?? { subscription, _ in
            if metadataURL != nil || credentialStore != nil {
                return UnsupportedUsageProvider(subscription: subscription)
            }
            guard let definition = ProviderRegistry.definition(for: subscription.providerID) else {
                return UnsupportedUsageProvider(subscription: subscription)
            }
            return definition.makeUsageProvider(for: subscription)
        }

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

    private static var defaultCredentialURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }

    private var migrationService: CredentialMigrationService {
        CredentialMigrationService(metadataURL: metadataURL, credentialStore: credentials)
    }

    /// 导出迁移包。加解密在后台执行：PBKDF2 迭代开销不能让主线程卡住。
    func exportMigrationPackage(password: String) async throws -> Data {
        let service = migrationService
        let subscriptions = subscriptions
        return try await Task.detached(priority: .userInitiated) {
            try service.exportPackage(subscriptions: subscriptions, password: password)
        }.value
    }

    /// 解密并生成导入方案（同样在后台执行）。
    func prepareMigrationImport(data: Data, password: String) async throws -> MigrationImportPlan {
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
            cancelActiveRefresh()
            await activeRefresh.value
        }
        let service = migrationService
        let localSubscriptions = subscriptions
        let imported = try await Task.detached(priority: .userInitiated) {
            try service.commit(plan, localSubscriptions: localSubscriptions)
        }.value
        subscriptions = imported
        snapshots.removeAll()
        subscriptionsLoadFailed = false
        lastPersistenceError = nil
        // 只允许这次已绑定新配置的受控刷新；普通入口仍被门闩拒绝。
        refreshAll(source: .manual, allowDuringMigration: true)
    }

    func add(_ subscription: Subscription) {
        guard canMutateSubscriptions else { return }
        subscriptions.append(subscription)
        saveSubscriptions()
    }

    /// 手动排序：按面板拖拽/辅助功能移动的结果调整数组顺序并持久化。
    /// 显示顺序即数组顺序（新增订阅追加到末尾），不再按 createdAt 排序。
    func moveSubscriptions(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard canMutateSubscriptions else { return }
        subscriptions.move(fromOffsets: source, toOffset: destination)
        saveSubscriptions()
    }

    func remove(_ subscription: Subscription) {
        guard canMutateSubscriptions else { return }
        subscriptions.removeAll { $0.id == subscription.id }
        snapshots.removeValue(forKey: subscription.id)
        alerts.remove(subscriptionID: subscription.id)
        try? credentials.remove(for: subscription.id)
        invalidateRefresh(for: subscription)
        saveSubscriptions()
    }

    func rename(_ subscription: Subscription, to name: String) {
        guard canMutateSubscriptions, let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].name = name
        saveSubscriptions()
    }

    func updateAuthMethod(_ subscription: Subscription, to authMethodID: AuthMethodID) {
        guard canMutateSubscriptions, let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].authMethodID = authMethodID
        invalidateRefresh(for: subscription)
        saveSubscriptions()
    }

    /// Call immediately before replacing credentials, including re-authentication with the same method.
    func invalidateRefresh(for subscription: Subscription) {
        configurationGeneration += 1
        cancelActiveRefresh()
    }

    /// 写入进度条配色。配色按订阅、按卡片样式隔离存储，按额度标识（名称 / 语义类型 / 默认项）寻址：
    /// 切换卡片样式后各样式已有的颜色仍然生效。
    /// 旧数据里为「没有进度条的卡片」（如余额型）配置过的颜色会原样保留，
    /// 只不再被消费与展示，不在此处清理（避免静默销毁用户数据）。
    func updateQuotaColors(_ quotaColors: SubscriptionQuotaPalette, for subscription: Subscription) {
        guard canMutateSubscriptions, let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].quotaColors = quotaColors
        saveSubscriptions()
    }

    func updateCardStyle(_ cardStyle: SubscriptionCardStyle, for subscription: Subscription) {
        guard canMutateSubscriptions, let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].cardStyle = cardStyle
        saveSubscriptions()
    }

    /// 刷新单个订阅。串行执行：若已有刷新在进行则忽略（与旧行为一致）。
    func refresh(_ subscription: Subscription, source: RefreshSource = .manual) {
        launchRefresh { store, refreshID in
            await store.fetch(subscription, source: source, refreshID: refreshID)
        }
    }

    /// 刷新全部启用的订阅，有界并发：每批最多同时刷新 `refreshBatchSize` 个订阅，
    /// 批间串行。凭证文件的 read-modify-write 已在 `CredentialStore` 内部串行化，
    /// 并发刷新不会互相覆盖。
    func refreshAll(source: RefreshSource = .manual) {
        refreshAll(source: source, allowDuringMigration: false)
    }

    private func refreshAll(source: RefreshSource, allowDuringMigration: Bool) {
        launchRefresh(allowDuringMigration: allowDuringMigration) { store, refreshID in
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
                            await store.fetch(subscription, source: source, refreshID: refreshID)
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

    private var canMutateSubscriptions: Bool {
        guard !migrationInProgress else { return false }
        guard !subscriptionsLoadFailed else {
            lastPersistenceError = "订阅配置文件无法读取，已阻止修改以保留原文件。"
            return false
        }
        return true
    }

    /// Explicitly retry after repairing or replacing the metadata file.
    func retryLoadingSubscriptions() {
        guard !migrationInProgress else { return }
        loadSubscriptions()
    }

    private func loadSubscriptions() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            subscriptionsLoadFailed = false
            lastPersistenceError = nil
            return
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            subscriptions = try decoder.decode([Subscription].self, from: data)
            subscriptionsLoadFailed = false
            lastPersistenceError = nil
        } catch {
            subscriptionsLoadFailed = true
            lastPersistenceError = "订阅配置文件无法读取，原文件已保留。"
            UsageStoreLogger.logger.error("subscriptions metadata load failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveSubscriptions() {
        guard !subscriptionsLoadFailed else {
            lastPersistenceError = "订阅配置文件无法读取，已阻止覆盖原文件。"
            return
        }
        do {
            let directory = metadataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(subscriptions).write(to: metadataURL, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            UsageStoreLogger.logger.error("subscriptions metadata write failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 刷新执行

/// 刷新任务的启动/取消、单订阅执行与错误折叠单独放扩展里，避免主类型体过长
/// （`private` 在文件内可见，行为不变）。
extension UsageStore {
    /// 以 store 自持任务的方式启动一段刷新：任务句柄被保存，
    /// 删除订阅或切换认证方式时可通过 `cancelActiveRefresh` 取消，
    /// 阻止网络返回后把快照或凭证写回已失效的订阅。
    private func launchRefresh(allowDuringMigration: Bool = false, _ operation: @escaping @MainActor (UsageStore, UUID) async -> Void) {
        guard (!migrationInProgress || allowDuringMigration), activeRefresh == nil else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        activeRefresh = Task { @MainActor [weak self] in
            guard let self, self.activeRefreshID == refreshID else { return }
            isRefreshing = true
            defer {
                if activeRefreshID == refreshID {
                    isRefreshing = false
                    lastRefreshAt = .now
                    activeRefresh = nil
                }
            }
            await operation(self, refreshID)
        }
    }

    private func cancelActiveRefresh() {
        activeRefreshID = UUID()
        activeRefresh?.cancel()
        activeRefresh = nil
        isRefreshing = false
    }

    private func fetch(_ subscription: Subscription, source: RefreshSource, refreshID: UUID) async {
        UsageStoreLogger.logger.debug("fetch started provider=\(subscription.providerID.rawValue, privacy: .public)")
        // 记录刷新开始时的配置代数；结束时配置已变更
        // （删除/切换认证方式）则丢弃结果。
        let generation = configurationGeneration
        do {
            guard ProviderRegistry.definition(for: subscription.providerID) != nil else {
                throw UsageProviderError.unsupported(subscription.providerID)
            }
            let snapshot = try await providerFactory(subscription, credentials).fetchUsage()
            guard isRefreshCurrent(refreshID), isStillCurrent(subscription, generation: generation) else {
                clearStaleCredentialsIfRemoved(subscription)
                return
            }
            let previous = snapshots[subscription.id]
            snapshots[subscription.id] = snapshot
            alerts.process(previous: previous, current: snapshot, subscription: subscription, source: source)
            lastSuccessfulRefreshAt = .now
        } catch is CancellationError {
            UsageStoreLogger.logger.debug("fetch cancelled provider=\(subscription.providerID.rawValue, privacy: .public)")
        } catch {
            guard isRefreshCurrent(refreshID), isStillCurrent(subscription, generation: generation) else {
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
                    quotas: [], updatedAt: .now,
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
                    quotas: [], updatedAt: .now,
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

    private func isRefreshCurrent(_ refreshID: UUID) -> Bool { activeRefreshID == refreshID }

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
}
