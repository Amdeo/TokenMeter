import Foundation

struct CredentialMigrationEnvelope: Codable, Sendable {
    let magic: String
    let schemaVersion: Int
    let iterations: Int
    let salt: Data
    let nonce: Data
    let ciphertext: Data
}

struct CredentialMigrationPayload: Codable, Sendable {
    let subscriptions: [MigrationSubscriptionWire]
}

/// 独立的可选字段 DTO：单条错误不会使整个已认证迁移包失效。
struct MigrationSubscriptionWire: Codable, Sendable {
    enum CodingKeys: String, CodingKey { case subscription, credential }

    let subscription: Subscription?
    let credential: CredentialEntry?
}

enum MigrationCredentialAction: Sendable, Equatable {
    case replace(CredentialEntry)
    case preserveLocal
    case removeLocal
    case none
}

enum MigrationImportKind: Sendable, Equatable {
    case add
    case update
    case skip(String)
}

struct MigrationImportItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let subscription: Subscription
    let kind: MigrationImportKind
    var credentialAction: MigrationCredentialAction
    let authMethodChanged: Bool
    let isExpired: Bool
    var isSelected: Bool

    var requiresCredentialRemoval: Bool { credentialAction == .removeLocal }
    var replacesCredentialAfterAuthMethodChange: Bool {
        guard authMethodChanged else { return false }
        if case .replace = credentialAction { return true }
        return false
    }
}

struct MigrationImportPlan: Sendable {
    let items: [MigrationImportItem]

    var selectedItems: [MigrationImportItem] { items.filter(\.isSelected) }
    var addCount: Int { selectedItems.filter { if case .add = $0.kind { return true }; return false }.count }
    var updateCount: Int { selectedItems.filter { if case .update = $0.kind { return true }; return false }.count }
    var credentialReplacementCount: Int { selectedItems.filter { if case .replace = $0.credentialAction { return true }; return false }.count }
    var authMethodChangeCredentialReplacementCount: Int {
        selectedItems.filter { $0.replacesCredentialAfterAuthMethodChange && $0.kind == .update }.count
    }
    var credentialRemovalCount: Int { selectedItems.filter { $0.credentialAction == .removeLocal }.count }
    var skippedItems: [MigrationImportItem] { items.filter { if case .skip = $0.kind { return true }; return false } }

    func updating(_ item: MigrationImportItem) -> MigrationImportPlan {
        MigrationImportPlan(items: items.map { $0.id == item.id ? item : $0 })
    }

    func updatingCredentialAction(_ action: MigrationCredentialAction, for id: UUID) -> MigrationImportPlan {
        MigrationImportPlan(items: items.map {
            guard $0.id == id else { return $0 }
            var item = $0
            item.credentialAction = action
            return item
        })
    }
}

enum CredentialMigrationError: LocalizedError, Equatable {
    case passwordTooShort
    case invalidPackage
    case unsupportedVersion
    case passwordOrFileCorrupt
    case credentialStoreUnreadable
    case transactionFailed
    case recoveryFailed

    var errorDescription: String? {
        switch self {
        case .passwordTooShort: "迁移包密码至少需要 12 个字符"
        case .unsupportedVersion: "迁移包来自更高版本的 TokenMeter，请先升级应用"
        case .credentialStoreUnreadable: "本地凭据文件无法读取，未生成迁移包"
        case .transactionFailed: "导入未完成，已恢复本地数据"
        case .recoveryFailed: "检测到未完成迁移，但无法安全恢复本地数据"
        case .invalidPackage, .passwordOrFileCorrupt: "密码错误或文件已损坏"
        }
    }
}
