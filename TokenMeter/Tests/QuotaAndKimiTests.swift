import Foundation
import Testing
@testable import TokenMeter

struct QuotaAndKimiTests {
    @Test
    func credentialStoreSavesReadsAndRemovesAPIKey() throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: fileURL)
        let subscriptionID = UUID()

        try store.save(apiKey: "  test-key  ", for: subscriptionID)

        #expect(store.apiKey(for: subscriptionID) == "test-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try store.remove(for: subscriptionID)
        #expect(store.apiKey(for: subscriptionID) == nil)
    }

    @Test
    func credentialStoreSavesReadsAndRemovesOAuthCredential() throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: fileURL)
        let subscriptionID = UUID()
        let credential = OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            tokenType: "Bearer"
        )

        try store.save(oauthCredential: credential, for: subscriptionID)

        #expect(store.oauthCredential(for: subscriptionID) == credential)
        try store.remove(for: subscriptionID)
        #expect(store.oauthCredential(for: subscriptionID) == nil)
    }

    @Test
    func credentialStoreSavesReadsAndRemovesBrowserCredential() throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = CredentialStore(fileURL: fileURL)
        let subscriptionID = UUID()
        let credential = KimiBrowserCredential(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            tokenType: "Bearer"
        )

        try store.save(browserCredential: credential, for: subscriptionID)

        #expect(store.browserCredential(for: subscriptionID) == credential)
        try store.remove(for: subscriptionID)
        #expect(store.browserCredential(for: subscriptionID) == nil)
    }

    @Test(arguments: [Data(), Data("not-json".utf8)])
    func credentialStoreDoesNotOverwriteEmptyOrCorruptFile(_ original: Data) throws {
        let fileURL = temporaryCredentialFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: fileURL)
        let store = CredentialStore(fileURL: fileURL)

        var didThrow = false
        do {
            try store.save(apiKey: "replacement", for: UUID())
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(try Data(contentsOf: fileURL) == original)
    }

    @Test
    func deepSeekBalanceQuotaKeepsCurrencyUnit() {
        let quota = Quota(name: "可用余额", used: 0, limit: 12.34, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)

        #expect(quota.kind == .balance)
        #expect(quota.unit == .currency(code: "USD", scale: 1))
        #expect(quota.remainingText == "USD 12.34")
    }

    @Test
    func deepSeekBalanceQuotaPreservesNegativeValue() {
        let quota = Quota(name: "可用余额", used: 0, limit: -3.50, resetAt: nil, unit: .currency(code: "USD", scale: 1), kind: .balance)

        #expect(quota.remainingText == "USD -3.50")
    }

    @Test
    func oldQuotaDataDefaultsToGenericKind() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"旧额度","used":1,"limit":2,"resetAt":null}
        """.utf8)

        let quota = try JSONDecoder().decode(Quota.self, from: data)
        #expect(quota.kind == .generic)
    }

    @Test
    func oldUsageSnapshotDataDefaultsOverallUsageRatioToNil() throws {
        let data = Data("""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "subscriptionID":"00000000-0000-0000-0000-000000000002",
          "platform":"Kimi",
          "quotas":[],
          "updatedAt":0,
          "isDemo":false,
          "errorMessage":null,
          "state":"realtime"
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)

        #expect(snapshot.overallUsageRatio == nil)
    }

    @Test
    func kimiCodingUsageMapsCoreWindowsAndDeduplicatesSemanticKinds() throws {
        let data = Data("""
        {
          "usage": {"used": 100, "limit": 1000, "resetTime": "2030-01-08T00:00:00Z"},
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"used": 0, "limit": 100, "resetTime": "2030-01-01T00:00:00Z"}},
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"used": 60, "limit": 100, "resetTime": "2030-01-01T00:00:00Z"}},
            {"window": {"duration": 1, "timeUnit": "TIME_UNIT_WEEK"}, "detail": {"used": 200, "limit": 1000, "resetTime": "2030-01-08T00:00:00Z"}}
          ],
          "totalQuota": {"limit": 5000, "remaining": 4000, "resetTime": "2030-02-01T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)

        let snapshot = try KimiUsageProvider.parseCodingUsage(response, subscription: subscription)
        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly, .monthly])
        #expect(snapshot.quotas.map(\.name) == ["5 小时额度", "每周额度", "月度额度"])
        #expect(snapshot.quotas[0].fraction == 0)
        #expect(snapshot.quotas[0].usedText == "0")
    }

    @Test
    func kimiMissingMonthlyQuotaRemainsMissing() throws {
        let data = Data("""
        {
          "usage": {"used": 100, "limit": 1000},
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"used": 50, "limit": 100}}
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)

        let snapshot = try KimiUsageProvider.parseCodingUsage(response, subscription: subscription)
        #expect(!snapshot.quotas.contains { $0.kind == .monthly })
    }

    @Test
    func kimiDirectLimitWindowIsParsedAsFiveHourQuota() throws {
        let data = Data("""
        {
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "limit": "1000", "remaining": "750"}
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)

        let snapshot = try KimiUsageProvider.parseCodingUsage(response, subscription: subscription)
        let fiveHour = try #require(snapshot.quotas.first { $0.kind == .fiveHour })

        #expect(fiveHour.used == 250)
        #expect(fiveHour.limit == 1000)
    }

    @Test
    func kimiFiveHourWindowUsesRemainingWhenUsedIsOmitted() throws {
        let data = Data("""
        {
          "limits": [
            {"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": 1000, "remaining": 750}}
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiUsagesResponse.self, from: data)
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)

        let snapshot = try KimiUsageProvider.parseCodingUsage(response, subscription: subscription)
        let fiveHour = try #require(snapshot.quotas.first { $0.kind == .fiveHour })

        #expect(fiveHour.used == 250)
        #expect(fiveHour.limit == 1000)
    }

    @Test
    func kimiBalanceSnapshotIsIdentifiableAsFallbackMode() {
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .manualAPIKey)
        let snapshot = UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "可用余额", used: 0, limit: 8, resetAt: nil, kind: .balance)
        ])
        let coreKinds: Set<Quota.Kind> = [.fiveHour, .weekly, .monthly]

        #expect(!snapshot.quotas.contains { coreKinds.contains($0.kind) })
        #expect(snapshot.quotas.contains { $0.kind == .balance })
    }

    @Test
    func kimiSubscriptionStatsMapsTotalAndWeeklyUsageAndTreatsEnabledMissingFiveHourRatioAsZero() throws {
        let data = Data("""
        {
          "ratelimitCode5h": {"enabled": true, "resetTime": "2030-01-01T00:00:00Z"},
          "ratelimitCode7d": {"ratio": 0.558, "resetTime": "2030-01-07T00:00:00Z"},
          "subscriptionBalance": {"amountUsedRatio": 0.872, "expireTime": "2030-02-01T00:00:00Z"}
        }
        """.utf8)
        let response = try JSONDecoder().decode(KimiSubscriptionStatsResponse.self, from: data)
        let subscription = Subscription(platform: .kimi, name: "Kimi", authMethod: .kimiBrowserSession)

        let snapshot = try KimiUsageProvider.parseSubscriptionStats(response, subscription: subscription)

        #expect(snapshot.overallUsageRatio == 0.872)
        #expect(snapshot.quotas.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.quotas[0].fraction == 0)
        #expect(snapshot.quotas[0].usedText == "0")
        #expect(snapshot.quotas[1].fraction == 0.558)
    }

    @Test
    func chromeSessionPayloadValidatesJWTExpiryAndFields() throws {
        let future = Date.now.addingTimeInterval(3_600).timeIntervalSince1970
        let access = makeJWT(exp: future)
        let refresh = makeJWT(exp: future + 86_400)
        let raw = "{\"accessToken\":\"\(access)\",\"refreshToken\":\"\(refresh)\"}"

        let credential = try ChromeSessionImporter.credential(from: raw)

        #expect(credential.tokenType == "Bearer")
        #expect(credential.expiresAt.timeIntervalSince1970 == Double(Int(future)))
    }

    @Test
    func chromeSessionPayloadRejectsExpiredToken() {
        let token = makeJWT(exp: Date.now.addingTimeInterval(-60).timeIntervalSince1970)
        let raw = "{\"accessToken\":\"\(token)\",\"refreshToken\":\"\(token)\"}"

        do {
            _ = try ChromeSessionImporter.credential(from: raw)
            #expect(Bool(false))
        } catch ChromeSessionImportError.expired {
            #expect(Bool(true))
        } catch {
            #expect(Bool(false))
        }
    }

    private func makeJWT(exp: TimeInterval) -> String {
        let payload = Data("{\"exp\":\(Int(exp))}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func temporaryCredentialFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenMeterTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }
}
