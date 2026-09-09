import CommonCrypto
import CryptoKit
import Foundation

struct CredentialMigrationService: Sendable {
    static let currentSchemaVersion = 1
    static let minimumPasswordLength = 12
    static let defaultIterations: UInt32 = 200_000
    static let minimumIterations: UInt32 = 100_000
    static let maximumIterations: UInt32 = 5_000_000
    static let maximumPackageBytes = 10 * 1_024 * 1_024
    static let maximumSubscriptionCount = 500

    private let metadataURL: URL
    private let credentialStore: CredentialStore
    private let journalURL: URL

    init(metadataURL: URL, credentialStore: CredentialStore, journalURL: URL? = nil) {
        self.metadataURL = metadataURL
        self.credentialStore = credentialStore
        self.journalURL = journalURL ?? metadataURL.deletingLastPathComponent().appendingPathComponent("migration-journal.json")
    }

    func exportPackage(subscriptions: [Subscription], password: String) throws -> Data {
        try validate(password: password)
        guard subscriptions.count <= Self.maximumSubscriptionCount else {
            throw CredentialMigrationError.invalidPackage
        }
        guard Set(subscriptions.map(\.id)).count == subscriptions.count else {
            throw CredentialMigrationError.invalidPackage
        }
        let credentials: CredentialStore.CredentialFile
        do {
            credentials = try credentialStore.snapshot()
        } catch {
            throw CredentialMigrationError.credentialStoreUnreadable
        }

        let subscriptionIDs = Set(subscriptions.map(\.id.uuidString))
        let relevantEntries = credentials.entries.filter { subscriptionIDs.contains($0.key) }

        let wires = try subscriptions.map { subscription in
            let entry = relevantEntries[subscription.id.uuidString]
            if let entry, validatedCredential(entry, for: subscription) == nil {
                throw CredentialMigrationError.credentialStoreUnreadable
            }
            return MigrationSubscriptionWire(subscription: subscription, credential: entry)
        }
        let payload = CredentialMigrationPayload(subscriptions: wires)
        let plaintext = try JSONEncoder().encode(payload)
        return try encrypt(plaintext, password: password)
    }

    func decryptPackage(_ data: Data, password: String) throws -> CredentialMigrationPayload {
        try validate(password: password)
        guard data.count <= Self.maximumPackageBytes else { throw CredentialMigrationError.invalidPackage }
        let envelope: CredentialMigrationEnvelope
        do {
            envelope = try JSONDecoder().decode(CredentialMigrationEnvelope.self, from: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["magic", "schemaVersion", "iterations", "salt", "nonce", "ciphertext"]
            else { throw CredentialMigrationError.invalidPackage }
        } catch let error as CredentialMigrationError {
            throw error
        } catch {
            throw CredentialMigrationError.invalidPackage
        }
        guard envelope.magic == "com.tokenmeter.migration" else { throw CredentialMigrationError.invalidPackage }
        guard envelope.schemaVersion <= Self.currentSchemaVersion else { throw CredentialMigrationError.unsupportedVersion }
        guard envelope.schemaVersion == Self.currentSchemaVersion,
              envelope.salt.count == 16,
              envelope.nonce.count == 12,
              envelope.iterations >= Int(Self.minimumIterations),
              envelope.iterations <= Int(Self.maximumIterations)
        else { throw CredentialMigrationError.invalidPackage }

        let key = try derivedKey(password: password, salt: envelope.salt, iterations: UInt32(envelope.iterations))
        // ciphertext carries the 16-byte AEAD tag at its tail to keep the outer schema compact.
        guard envelope.ciphertext.count >= 16 else { throw CredentialMigrationError.passwordOrFileCorrupt }
        let encrypted = envelope.ciphertext.dropLast(16)
        let tag = envelope.ciphertext.suffix(16)
        let authenticatedBox: AES.GCM.SealedBox
        do {
            authenticatedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: encrypted,
                tag: tag
            )
        } catch {
            throw CredentialMigrationError.passwordOrFileCorrupt
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(authenticatedBox, using: key)
        } catch {
            throw CredentialMigrationError.passwordOrFileCorrupt
        }
        guard plaintext.count <= Self.maximumPackageBytes else { throw CredentialMigrationError.invalidPackage }
        do {
            let payload = try JSONDecoder().decode(CredentialMigrationPayload.self, from: plaintext)
            guard payload.subscriptions.count <= Self.maximumSubscriptionCount else { throw CredentialMigrationError.invalidPackage }
            return payload
        } catch let error as CredentialMigrationError {
            throw error
        } catch {
            throw CredentialMigrationError.invalidPackage
        }
    }

    func makeImportPlan(
        payload: CredentialMigrationPayload,
        localSubscriptions: [Subscription],
        localCredentials: CredentialStore.CredentialFile
    ) -> MigrationImportPlan {
        let duplicateIDs = Set(
            Dictionary(grouping: payload.subscriptions.compactMap(\.subscription), by: \.id)
                .filter { $0.value.count > 1 }
                .keys
        )
        var localByID: [UUID: Subscription] = [:]
        for subscription in localSubscriptions {
            guard localByID[subscription.id] == nil else { continue }
            localByID[subscription.id] = subscription
        }
        var items: [MigrationImportItem] = []

        for wire in payload.subscriptions {
            guard let subscription = wire.subscription else { continue }
            if duplicateIDs.contains(subscription.id) {
                items.append(skip(subscription, "迁移包中存在重复订阅标识"))
                continue
            }
            guard ProviderRegistry.isSupported(subscription.providerID) else {
                items.append(skip(subscription, "当前版本不支持该供应商"))
                continue
            }
            let importedCredential = wire.credential.flatMap { validatedCredential($0, for: subscription) }
            let importedExpired = importedCredential.map(isExpired) ?? false
            guard let local = localByID[subscription.id] else {
                if let importedCredential {
                    items.append(MigrationImportItem(
                        id: subscription.id,
                        subscription: subscription,
                        kind: .add,
                        credentialAction: .replace(importedCredential),
                        authMethodChanged: false,
                        isExpired: importedExpired,
                        isSelected: true
                    ))
                } else {
                    items.append(skip(subscription, "新订阅没有有效凭据"))
                }
                continue
            }
            guard local.providerID == subscription.providerID else {
                items.append(skip(subscription, "同一订阅标识对应不同供应商"))
                continue
            }

            let localCredential = localCredentials.entries[subscription.id.uuidString]
            let localIsValid = localCredential.flatMap { validatedCredential($0, for: local) } != nil
            if let importedCredential {
                items.append(MigrationImportItem(
                    id: subscription.id,
                    subscription: subscription,
                    kind: .update,
                    credentialAction: .replace(importedCredential),
                    authMethodChanged: local.authMethodID != subscription.authMethodID,
                    isExpired: importedExpired,
                    isSelected: true
                ))
            } else if local.authMethodID == subscription.authMethodID, localIsValid {
                items.append(MigrationImportItem(
                    id: subscription.id,
                    subscription: subscription,
                    kind: .update,
                    credentialAction: .preserveLocal,
                    authMethodChanged: false,
                    isExpired: false,
                    isSelected: true
                ))
            } else if local.authMethodID != subscription.authMethodID, localIsValid {
                // 默认跳过。用户明确选中时才删除旧凭据并采用新认证方式。
                items.append(MigrationImportItem(
                    id: subscription.id,
                    subscription: subscription,
                    kind: .update,
                    credentialAction: .removeLocal,
                    authMethodChanged: true,
                    isExpired: false,
                    isSelected: false
                ))
            } else {
                items.append(skip(subscription, "导入与本地均无有效凭据"))
            }
        }
        return MigrationImportPlan(items: items)
    }

    /// 事务顺序：journal(旧订阅 + 新凭据哈希) → 新订阅 → 新凭据 → 哈希校验 → 删除 journal。
    /// 崩溃恢复只需比较凭据哈希；凭据总在订阅之后写入，因此不会留下“新凭据 + 旧配置”。
    func commit(_ plan: MigrationImportPlan, localSubscriptions: [Subscription]) throws -> [Subscription] {
        try CredentialStore.withExclusiveAccess {
            let currentCredentials: CredentialStore.CredentialFile
            do {
                currentCredentials = try credentialStore.snapshot()
            } catch {
                throw CredentialMigrationError.credentialStoreUnreadable
            }
            var subscriptions = localSubscriptions
            var credentials = currentCredentials
            for item in plan.selectedItems {
                switch item.kind {
                case .add:
                    subscriptions.append(item.subscription)
                case .update:
                    guard let index = subscriptions.firstIndex(where: { $0.id == item.id }) else { continue }
                    subscriptions[index] = item.subscription
                case .skip:
                    continue
                }
                switch item.credentialAction {
                case .replace(let entry):
                    credentials.entries[item.id.uuidString] = entry
                case .removeLocal:
                    credentials.entries.removeValue(forKey: item.id.uuidString)
                case .preserveLocal, .none:
                    break
                }
            }

            let encoder = JSONEncoder()
            let oldSubscriptions: Data
            if let existing = try? Data(contentsOf: metadataURL) {
                oldSubscriptions = existing
            } else {
                oldSubscriptions = try encoder.encode(localSubscriptions)
            }
            let newSubscriptions = try encoder.encode(subscriptions)
            let newCredentials = try encoder.encode(credentials)
            let journal = MigrationJournal(
                staged: true,
                oldSubscriptions: oldSubscriptions,
                newCredentialsHash: Data(SHA256.hash(data: newCredentials))
            )
            var subscriptionsWritten = false
            var credentialsWritten = false
            do {
                try writePrivate(try encoder.encode(journal), to: journalURL)
                try writePrivate(newSubscriptions, to: metadataURL)
                subscriptionsWritten = true
                try credentialStore.replace(withEncoded: newCredentials)
                credentialsWritten = true
                let onDiskCredentials = try Data(contentsOf: credentialStore.storageURL)
                guard Data(SHA256.hash(data: onDiskCredentials)) == journal.newCredentialsHash else {
                    throw CredentialMigrationError.transactionFailed
                }
                // journal 删除失败不回滚：两份数据已一致，保留 journal 供下次幂等清理。
                try? FileManager.default.removeItem(at: journalURL)
                return subscriptions
            } catch {
                if !subscriptionsWritten {
                    try? FileManager.default.removeItem(at: journalURL)
                } else if !credentialsWritten || (try? Data(contentsOf: credentialStore.storageURL)).map({ Data(SHA256.hash(data: $0)) != journal.newCredentialsHash }) == true {
                    // 不备份凭据明文；回滚只恢复订阅，凭据由写入顺序和下次启动恢复保持一致。
                    do {
                        try recoverInterruptedTransaction()
                    } catch {
                        throw CredentialMigrationError.recoveryFailed
                    }
                }
                throw CredentialMigrationError.transactionFailed
            }
        }
    }

    /// 应用启动时调用。若凭据哈希未匹配，则订阅写入尚未与凭据一起提交，回滚订阅即可。
    func recoverInterruptedTransaction() throws {
        try CredentialStore.withExclusiveAccess {
            guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
            let journal: MigrationJournal
            do {
                journal = try JSONDecoder().decode(MigrationJournal.self, from: Data(contentsOf: journalURL))
                guard journal.staged,
                      journal.newCredentialsHash.count == 32,
                      (try? JSONDecoder().decode([Subscription].self, from: journal.oldSubscriptions)) != nil
                else { throw CredentialMigrationError.recoveryFailed }
            } catch let error as CredentialMigrationError {
                throw error
            } catch {
                throw CredentialMigrationError.recoveryFailed
            }
            let currentHash = (try? Data(contentsOf: credentialStore.storageURL)).map { Data(SHA256.hash(data: $0)) }
            if currentHash != journal.newCredentialsHash {
                do {
                    try writePrivate(journal.oldSubscriptions, to: metadataURL)
                } catch {
                    throw CredentialMigrationError.recoveryFailed
                }
            }
            // 内容已一致时删除失败也不改变数据；保留 journal 供下一次启动重试。
            try? FileManager.default.removeItem(at: journalURL)
        }
    }

    private func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let salt = randomData(count: 16)
        let iterations = calibratedIterations(password: password, salt: salt)
        let key = try derivedKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let envelope = CredentialMigrationEnvelope(
            magic: "com.tokenmeter.migration",
            schemaVersion: Self.currentSchemaVersion,
            iterations: Int(iterations),
            salt: salt,
            nonce: sealed.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealed.ciphertext + sealed.tag
        )
        return try JSONEncoder().encode(envelope)
    }

    private func validate(password: String) throws {
        guard password.count >= Self.minimumPasswordLength else { throw CredentialMigrationError.passwordTooShort }
    }

    private func calibratedIterations(password: String, salt: Data) -> UInt32 {
        let calibrationIterations = Self.defaultIterations
        let start = Date.now
        _ = try? derivedKey(password: password, salt: salt, iterations: calibrationIterations)
        let elapsed = max(Date.now.timeIntervalSince(start), 0.001)
        let target = 0.2
        let scaled = Double(calibrationIterations) * target / elapsed
        return UInt32(min(max(scaled, Double(Self.minimumIterations)), Double(Self.maximumIterations)))
    }

    private func derivedKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes,
                    password.lengthOfBytes(using: .utf8),
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &key,
                    key.count
                )
            }
        }
        guard status == kCCSuccess else { throw CredentialMigrationError.invalidPackage }
        return SymmetricKey(data: key)
    }

    private func validatedCredential(_ entry: CredentialEntry, for subscription: Subscription) -> CredentialEntry? {
        guard let flow = ProviderRegistry.authFlow(for: subscription.providerID, authMethodID: subscription.authMethodID) else { return nil }
        let present = [entry.apiKey != nil, entry.oauthCredential != nil, entry.browserCredential != nil, entry.cookieCredential != nil]
            .filter { $0 }
            .count
        guard present == 1 else { return nil }
        switch flow {
        case .apiKey:
            guard let key = entry.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
            return CredentialEntry(apiKey: key, oauthCredential: nil, browserCredential: nil, cookieCredential: nil)
        case .deviceOAuth:
            guard let credential = entry.oauthCredential,
                  !credential.accessToken.isEmpty, !credential.refreshToken.isEmpty, !credential.tokenType.isEmpty
            else { return nil }
            return CredentialEntry(apiKey: nil, oauthCredential: credential, browserCredential: nil, cookieCredential: nil)
        case .browserSession:
            if let credential = entry.browserCredential,
               !credential.accessToken.isEmpty, !credential.refreshToken.isEmpty, !credential.tokenType.isEmpty {
                return CredentialEntry(apiKey: nil, oauthCredential: nil, browserCredential: credential, cookieCredential: nil)
            }
            if let credential = entry.cookieCredential,
               !credential.sessionCookie.isEmpty, !credential.userID.isEmpty {
                return CredentialEntry(apiKey: nil, oauthCredential: nil, browserCredential: nil, cookieCredential: credential)
            }
            return nil
        }
    }

    private func isExpired(_ entry: CredentialEntry) -> Bool {
        entry.oauthCredential.map { $0.expiresAt <= .now } == true
            || entry.browserCredential.map { $0.expiresAt <= .now } == true
    }

    private func skip(_ subscription: Subscription, _ reason: String) -> MigrationImportItem {
        MigrationImportItem(
            id: subscription.id,
            subscription: subscription,
            kind: .skip(reason),
            credentialAction: .none,
            authMethodChanged: false,
            isExpired: false,
            isSelected: false
        )
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func randomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }
}

struct MigrationJournal: Codable {
    let staged: Bool
    let oldSubscriptions: Data
    let newCredentialsHash: Data
}

extension MigrationSubscriptionWire {
    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            subscription = nil
            credential = nil
            return
        }
        subscription = try? container.decode(Subscription.self, forKey: .subscription)
        credential = try? container.decode(CredentialEntry.self, forKey: .credential)
    }
}
