import Foundation
import Testing
@testable import TokenMeter

@MainActor
struct CredentialMigrationPackageTests {
    @Test
    func encryptedPackageRoundTripsWithoutPlaintextCredential() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("subscriptions.json")
        let credentialURL = directory.appendingPathComponent("credentials.json")
        let store = CredentialStore(fileURL: credentialURL)
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek")
        try store.save(apiKey: "private-api-key-value", for: subscription.id)
        let service = CredentialMigrationService(metadataURL: metadataURL, credentialStore: store)

        let package = try service.exportPackage(subscriptions: [subscription], password: "migration-password")
        let payload = try service.decryptPackage(package, password: "migration-password")

        #expect(!String(decoding: package, as: UTF8.self).contains("private-api-key-value"))
        #expect(payload.subscriptions.count == 1)
        #expect(payload.subscriptions.first?.subscription == subscription)
        #expect(payload.subscriptions.first?.credential?.apiKey == "private-api-key-value")
    }

    @Test
    func wrongPasswordAndTamperedPackageAreRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CredentialMigrationService(
            metadataURL: directory.appendingPathComponent("subscriptions.json"),
            credentialStore: CredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        )
        let subscription = Subscription(providerID: .deepSeek, name: "DeepSeek")
        let package = try service.exportPackage(subscriptions: [subscription], password: "migration-password")

        #expect(throws: CredentialMigrationError.self) {
            try service.decryptPackage(package, password: "wrong-migration-password")
        }
        var tampered = package
        tampered[tampered.startIndex] ^= 1
        #expect(throws: CredentialMigrationError.self) {
            try service.decryptPackage(tampered, password: "migration-password")
        }
    }

    @Test
    func importPlanUsesUUIDAndPreservesLocalCredentialForCredentiallessUpdate() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentialStore = CredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        let existing = Subscription(providerID: .deepSeek, name: "旧名称")
        try credentialStore.save(apiKey: "local-key", for: existing.id)
        var imported = existing
        imported.name = "新名称"
        let payload = CredentialMigrationPayload(subscriptions: [
            MigrationSubscriptionWire(subscription: imported, credential: nil)
        ])
        let service = CredentialMigrationService(
            metadataURL: directory.appendingPathComponent("subscriptions.json"),
            credentialStore: credentialStore
        )

        let plan = service.makeImportPlan(
            payload: payload,
            localSubscriptions: [existing],
            localCredentials: try credentialStore.snapshot()
        )

        #expect(plan.items.count == 1)
        #expect(plan.items[0].kind == .update)
        #expect(plan.items[0].credentialAction == .preserveLocal)
        #expect(plan.items[0].isSelected)
    }

    @Test
    func importPlanSkipsCredentiallessNewAndUnknownProviders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = CredentialMigrationService(
            metadataURL: directory.appendingPathComponent("subscriptions.json"),
            credentialStore: CredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        )
        let emptyCredential = Subscription(providerID: .deepSeek, name: "无凭据")
        let unknown = Subscription(providerID: ProviderID(rawValue: "unknown"), name: "未知")
        let payload = CredentialMigrationPayload(subscriptions: [
            MigrationSubscriptionWire(subscription: emptyCredential, credential: nil),
            MigrationSubscriptionWire(subscription: unknown, credential: CredentialEntry(apiKey: "key", oauthCredential: nil, browserCredential: nil, cookieCredential: nil))
        ])

        let plan = service.makeImportPlan(
            payload: payload,
            localSubscriptions: [],
            localCredentials: try CredentialStore(fileURL: directory.appendingPathComponent("credentials.json")).snapshot()
        )

        #expect(plan.items.count == 2)
        #expect(plan.skippedItems.count == 2)
        #expect(plan.selectedItems.isEmpty)
    }

    @Test
    func commitWritesSubscriptionAndCredentialThenClearsJournal() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("subscriptions.json")
        let credentialURL = directory.appendingPathComponent("credentials.json")
        let journalURL = directory.appendingPathComponent("migration-journal.json")
        let subscription = Subscription(providerID: .deepSeek, name: "迁移订阅")
        let credential = CredentialEntry(apiKey: "migration-key", oauthCredential: nil, browserCredential: nil, cookieCredential: nil)
        let service = CredentialMigrationService(
            metadataURL: metadataURL,
            credentialStore: CredentialStore(fileURL: credentialURL),
            journalURL: journalURL
        )
        let plan = MigrationImportPlan(items: [
            MigrationImportItem(
                id: subscription.id,
                subscription: subscription,
                kind: .add,
                credentialAction: .replace(credential),
                authMethodChanged: false,
                isExpired: false,
                isSelected: true
            )
        ])

        let committed = try service.commit(plan, localSubscriptions: [])

        #expect(committed == [subscription])
        #expect(try JSONDecoder().decode([Subscription].self, from: Data(contentsOf: metadataURL)) == [subscription])
        #expect(CredentialStore(fileURL: credentialURL).apiKey(for: subscription.id) == "migration-key")
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test
    func interruptedJournalRestoresOldSubscriptionsWhenCredentialHashDoesNotMatch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadataURL = directory.appendingPathComponent("subscriptions.json")
        let credentialURL = directory.appendingPathComponent("credentials.json")
        let journalURL = directory.appendingPathComponent("migration-journal.json")
        let old = Subscription(providerID: .deepSeek, name: "旧订阅")
        let newer = Subscription(providerID: .deepSeek, name: "新订阅")
        let oldData = try JSONEncoder().encode([old])
        try JSONEncoder().encode([newer]).write(to: metadataURL)
        try JSONEncoder().encode(CredentialStore.CredentialFile()).write(to: credentialURL)
        let journal = MigrationJournal(staged: true, oldSubscriptions: oldData, newCredentialsHash: Data(repeating: 0, count: 32))
        try JSONEncoder().encode(journal).write(to: journalURL)
        let service = CredentialMigrationService(
            metadataURL: metadataURL,
            credentialStore: CredentialStore(fileURL: credentialURL),
            journalURL: journalURL
        )

        try service.recoverInterruptedTransaction()

        #expect(try JSONDecoder().decode([Subscription].self, from: Data(contentsOf: metadataURL)) == [old])
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test
    func importPlanRequiresExplicitSelectionBeforeDeletingCredentialOnAuthChange() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentialStore = CredentialStore(fileURL: directory.appendingPathComponent("credentials.json"))
        let existing = Subscription(providerID: .kimi, name: "Kimi", authMethodID: .kimiDeviceOAuth)
        try credentialStore.save(oauthCredential: OAuthCredential(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture, tokenType: "Bearer"), for: existing.id)
        var imported = existing
        imported.authMethodID = .kimiBrowserSession
        let payload = CredentialMigrationPayload(subscriptions: [
            MigrationSubscriptionWire(subscription: imported, credential: nil)
        ])
        let service = CredentialMigrationService(
            metadataURL: directory.appendingPathComponent("subscriptions.json"),
            credentialStore: credentialStore
        )

        let plan = service.makeImportPlan(
            payload: payload,
            localSubscriptions: [existing],
            localCredentials: try credentialStore.snapshot()
        )

        #expect(plan.items[0].credentialAction == .removeLocal)
        #expect(plan.items[0].requiresCredentialRemoval)
        #expect(!plan.items[0].isSelected)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMeterMigrationTests.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
