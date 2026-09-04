import Foundation

struct OAuthCredential: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let tokenType: String
}

struct KimiBrowserCredential: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let tokenType: String
}

struct CredentialStore: Sendable {
    private struct Entry: Codable, Sendable {
        var apiKey: String?
        var oauthCredential: OAuthCredential?
        var browserCredential: KimiBrowserCredential?
    }

    private struct CredentialFile: Codable, Sendable {
        var entries: [String: Entry] = [:]
    }

    private let fileURL: URL

    init(fileURL: URL = CredentialStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    func apiKey(for subscriptionID: UUID) -> String? {
        try? load().entries[subscriptionID.uuidString]?.apiKey
    }

    func oauthCredential(for subscriptionID: UUID) -> OAuthCredential? {
        try? load().entries[subscriptionID.uuidString]?.oauthCredential
    }

    func browserCredential(for subscriptionID: UUID) -> KimiBrowserCredential? {
        try? load().entries[subscriptionID.uuidString]?.browserCredential
    }

    func isExpiringSoon(_ credential: OAuthCredential, now: Date = .now) -> Bool {
        credential.expiresAt.timeIntervalSince(now) <= 300
    }

    func save(apiKey: String, for subscriptionID: UUID) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CredentialStoreError.emptyCredential }
        var file = try load()
        var entry = file.entries[subscriptionID.uuidString] ?? Entry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
        entry.apiKey = value
        entry.oauthCredential = nil
        file.entries[subscriptionID.uuidString] = entry
        try write(file)
    }

    func save(oauthCredential: OAuthCredential, for subscriptionID: UUID) throws {
        var file = try load()
        var entry = file.entries[subscriptionID.uuidString] ?? Entry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
        entry.apiKey = nil
        entry.oauthCredential = oauthCredential
        file.entries[subscriptionID.uuidString] = entry
        try write(file)
    }

    func save(browserCredential: KimiBrowserCredential, for subscriptionID: UUID) throws {
        var file = try load()
        var entry = file.entries[subscriptionID.uuidString] ?? Entry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
        entry.browserCredential = browserCredential
        file.entries[subscriptionID.uuidString] = entry
        try write(file)
    }

    func remove(for subscriptionID: UUID) throws {
        var file = try load()
        guard file.entries.removeValue(forKey: subscriptionID.uuidString) != nil else { return }
        try write(file)
    }

    private func load() throws -> CredentialFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return CredentialFile() }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw CredentialStoreError.invalidFile }
        do {
            return try JSONDecoder().decode(CredentialFile.self, from: data)
        } catch {
            throw CredentialStoreError.invalidFile
        }
    }

    private func write(_ file: CredentialFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMeter", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }
}

enum CredentialStoreError: LocalizedError {
    case emptyCredential
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .emptyCredential: "凭证不能为空"
        case .invalidFile: "本地凭证文件无法读取，请删除后重新配置凭证"
        }
    }
}
