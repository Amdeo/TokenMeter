import Foundation

struct OAuthCredential: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let tokenType: String
    let accountID: String?

    init(accessToken: String, refreshToken: String, expiresAt: Date, tokenType: String, accountID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.accountID = accountID
    }
}

struct KimiBrowserCredential: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let tokenType: String
}

/// HttpOnly session cookie 会话凭证（new-api 新版认证：cookie + 用户 ID 头，无 refresh）。
struct CookieSessionCredential: Codable, Sendable, Equatable {
    let sessionCookie: String
    let userID: String
}

/// 浏览器会话登录的结果：token 型（Kimi/CCBus/APIKEY.FUN）或 cookie 型（new-api 新版）。
enum BrowserLoginResult: Sendable, Equatable {
    case token(KimiBrowserCredential)
    case cookie(CookieSessionCredential)
}

/// 凭证文件中的单条订阅条目（互斥字段：一次只保存一种认证方式的凭据）。
struct CredentialEntry: Codable, Sendable, Equatable {
    var apiKey: String?
    var oauthCredential: OAuthCredential?
    var browserCredential: KimiBrowserCredential?
    var cookieCredential: CookieSessionCredential?
}

/// 通用存储凭据：按订阅 ID 保存，互斥（一次只保留一种认证方式的凭据）。
enum StoredCredential: Sendable, Equatable {
    case apiKey(String)
    case oauth(OAuthCredential)
    case browserSession(KimiBrowserCredential)
    case cookieSession(CookieSessionCredential)

    /// 从旧 Entry 中解析对应 flow 的凭据。
    static func from(entry: CredentialEntry, flowID: AuthFlowID) -> StoredCredential? {
        switch flowID {
        case .apiKey:
            return entry.apiKey.map { .apiKey($0) }
        case .deviceOAuth:
            return entry.oauthCredential.map { .oauth($0) }
        case .oauthCode:
            return entry.oauthCredential.map { .oauth($0) }
        case .browserSession:
            return entry.browserCredential.map { .browserSession($0) } ?? entry.cookieCredential.map { .cookieSession($0) }
        }
    }

    /// 写入 Entry 时互斥清空其他字段。
    func apply(to entry: inout CredentialEntry) {
        switch self {
        case .apiKey(let key):
            entry.apiKey = key
            entry.oauthCredential = nil
            entry.browserCredential = nil
            entry.cookieCredential = nil
        case .oauth(let credential):
            entry.apiKey = nil
            entry.oauthCredential = credential
            entry.browserCredential = nil
            entry.cookieCredential = nil
        case .browserSession(let credential):
            entry.apiKey = nil
            entry.oauthCredential = nil
            entry.browserCredential = credential
            entry.cookieCredential = nil
        case .cookieSession(let credential):
            entry.apiKey = nil
            entry.oauthCredential = nil
            entry.browserCredential = nil
            entry.cookieCredential = credential
        }
    }
}

struct CredentialStore: Sendable {
    struct CredentialFile: Codable, Sendable {
        var entries: [String: CredentialEntry] = [:]
    }

    /// 所有实例共享同一把锁：Provider 可能各自创建 store，实例锁无法保护同一文件。
    private static let fileLock = NSRecursiveLock()
    private let fileURL: URL

    init(fileURL: URL = CredentialStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    var storageURL: URL { fileURL }

    static func withExclusiveAccess<T>(_ operation: () throws -> T) rethrows -> T {
        try fileLock.withLock(operation)
    }

    func snapshot() throws -> CredentialFile {
        try Self.withExclusiveAccess { try load() }
    }

    func encodedSnapshot() throws -> Data {
        try Self.withExclusiveAccess { try JSONEncoder().encode(load()) }
    }

    func replace(with file: CredentialFile) throws {
        try Self.withExclusiveAccess { try write(file) }
    }

    /// 迁移事务写入预先编码并已校验的完整凭据文件，保留字节哈希以供 journal 恢复判断。
    func replace(withEncoded data: Data) throws {
        try Self.withExclusiveAccess {
            guard !data.isEmpty, (try? JSONDecoder().decode(CredentialFile.self, from: data)) != nil else {
                throw CredentialStoreError.invalidFile
            }
            try writeEncoded(data)
        }
    }

    func apiKey(for subscriptionID: UUID) -> String? {
        Self.fileLock.withLock {
            try? load().entries[subscriptionID.uuidString]?.apiKey
        }
    }

    func oauthCredential(for subscriptionID: UUID) -> OAuthCredential? {
        Self.fileLock.withLock {
            try? load().entries[subscriptionID.uuidString]?.oauthCredential
        }
    }

    func browserCredential(for subscriptionID: UUID) -> KimiBrowserCredential? {
        Self.fileLock.withLock {
            try? load().entries[subscriptionID.uuidString]?.browserCredential
        }
    }

    func cookieSession(for subscriptionID: UUID) -> CookieSessionCredential? {
        Self.fileLock.withLock {
            try? load().entries[subscriptionID.uuidString]?.cookieCredential
        }
    }

    /// 按认证流程读取通用凭据（新认证方式接入的统一入口）。
    func credential(for subscriptionID: UUID, flowID: AuthFlowID) -> StoredCredential? {
        Self.fileLock.withLock {
            guard let entry = try? load().entries[subscriptionID.uuidString] else { return nil }
            return StoredCredential.from(entry: entry, flowID: flowID)
        }
    }

    /// 保存通用凭据（互斥：同一订阅只保留当前认证方式的凭据）。
    func save(_ credential: StoredCredential, for subscriptionID: UUID) throws {
        try Self.fileLock.withLock {
            var file = try load()
            var entry = file.entries[subscriptionID.uuidString] ??
                    CredentialEntry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
            credential.apply(to: &entry)
            file.entries[subscriptionID.uuidString] = entry
            try write(file)
        }
    }

    func isExpiringSoon(_ credential: OAuthCredential, now: Date = .now) -> Bool {
        credential.expiresAt.timeIntervalSince(now) <= 300
    }

    func save(apiKey: String, for subscriptionID: UUID) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CredentialStoreError.emptyCredential }
        try Self.fileLock.withLock {
            var file = try load()
            var entry = file.entries[subscriptionID.uuidString] ??
                    CredentialEntry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
            StoredCredential.apiKey(value).apply(to: &entry)
            file.entries[subscriptionID.uuidString] = entry
            try write(file)
        }
    }

    func save(oauthCredential: OAuthCredential, for subscriptionID: UUID) throws {
        try Self.fileLock.withLock {
            var file = try load()
            var entry = file.entries[subscriptionID.uuidString] ??
                    CredentialEntry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
            StoredCredential.oauth(oauthCredential).apply(to: &entry)
            file.entries[subscriptionID.uuidString] = entry
            try write(file)
        }
    }

    func save(browserCredential: KimiBrowserCredential, for subscriptionID: UUID) throws {
        try Self.fileLock.withLock {
            var file = try load()
            var entry = file.entries[subscriptionID.uuidString] ??
                    CredentialEntry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
            StoredCredential.browserSession(browserCredential).apply(to: &entry)
            file.entries[subscriptionID.uuidString] = entry
            try write(file)
        }
    }

    func save(cookieSession: CookieSessionCredential, for subscriptionID: UUID) throws {
        try Self.fileLock.withLock {
            var file = try load()
            var entry = file.entries[subscriptionID.uuidString] ??
                    CredentialEntry(apiKey: nil, oauthCredential: nil, browserCredential: nil)
            StoredCredential.cookieSession(cookieSession).apply(to: &entry)
            file.entries[subscriptionID.uuidString] = entry
            try write(file)
        }
    }

    func remove(for subscriptionID: UUID) throws {
        try Self.fileLock.withLock {
            var file = try load()
            guard file.entries.removeValue(forKey: subscriptionID.uuidString) != nil else { return }
            try write(file)
        }
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
        try writeEncoded(JSONEncoder().encode(file))
    }

    private func writeEncoded(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
