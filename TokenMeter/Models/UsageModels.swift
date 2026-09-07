import Foundation
import AppKit
import SwiftUI

struct Subscription: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let platform: Platform
    var name: String
    var authMethod: AuthMethod
    let createdAt: Date
    var isEnabled: Bool
    var quotaColors: [String: UInt32]

    init(
        id: UUID = UUID(),
        platform: Platform,
        name: String,
        authMethod: AuthMethod,
        createdAt: Date = .now,
        isEnabled: Bool = true,
        quotaColors: [String: UInt32] = [:]
    ) {
        self.id = id
        self.platform = platform
        self.name = name
        self.authMethod = authMethod
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.quotaColors = quotaColors
    }

    enum AuthMethod: String, Codable, Sendable {
        case manualAPIKey
        case kimiOAuth
        case kimiBrowserSession

        var label: String {
            switch self {
            case .manualAPIKey: "手动 API Key"
            case .kimiOAuth: "Kimi Code OAuth"
            case .kimiBrowserSession: "Kimi 网页登录态"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, platform, name, authMethod, createdAt, isEnabled, quotaColors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        platform = try container.decode(Platform.self, forKey: .platform)
        name = try container.decode(String.self, forKey: .name)
        let rawAuthMethod = try container.decode(String.self, forKey: .authMethod)
        switch rawAuthMethod {
        case "piAuth", "officialAuth":
            authMethod = .manualAPIKey
        default:
            authMethod = AuthMethod(rawValue: rawAuthMethod) ?? .manualAPIKey
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        quotaColors = try container.decodeIfPresent([String: UInt32].self, forKey: .quotaColors) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(platform, forKey: .platform)
        try container.encode(name, forKey: .name)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(quotaColors, forKey: .quotaColors)
    }
}

// MARK: - 额度颜色配置

/// 订阅额度进度条颜色的键定义与解析逻辑。
/// 值统一使用不透明的 6 位 sRGB（0xRRGGBB），避免直接持久化 SwiftUI `Color`。
enum SubscriptionQuotaColors: Sendable {
    /// Kimi「总使用量」聚合比例的键。
    static let overallKey = "overall"
    /// 未配置额度的回退键。
    static let genericKey = "generic"
    /// 语义稳定的额度窗口键。
    static let fiveHourKey = "kind.fiveHour"
    static let weeklyKey = "kind.weekly"

    /// Kimi 总使用量的内置默认色。
    static let overallDefault: Color = .indigo

    /// 八个适配明暗主题的高对比预设色（避开橙/红，保留给状态语义）。
    static let presets: [UInt32] = [
        0x6366F1, 0x3B82F6, 0x06B6D4, 0x14B8A6,
        0x22C55E, 0xA855F7, 0xEC4899, 0x64748B
    ]

    /// 把额度名称规范化为 `name.<...>` 专属键：去首尾空白、小写、压缩连续空白。
    static func nameKey(_ name: String) -> String {
        let normalized = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return "name.\(normalized)"
    }

    /// 语义类型键；没有对应类型的额度返回 nil。
    static func kindKey(for kind: Quota.Kind) -> String? {
        switch kind {
        case .fiveHour: fiveHourKey
        case .weekly: weeklyKey
        case .generic, .balance: nil
        }
    }

    /// 内置默认色：5 小时蓝、每周绿，其余额度使用协调的青色。
    static func defaultColor(forKind kind: Quota.Kind) -> Color {
        switch kind {
        case .fiveHour: .blue
        case .weekly: .green
        case .generic, .balance: .teal
        }
    }

    /// 解析单个额度窗口的颜色：名称专属 → 语义类型 → generic 回退 → 内置默认。
    static func resolve(_ colors: [String: UInt32], quota: Quota) -> Color {
        resolve(colors, name: quota.name, kind: quota.kind)
    }

    /// 按名称与类型解析（编辑页在没有完整 Quota 时也能得到正确默认色）。
    static func resolve(_ colors: [String: UInt32], name: String, kind: Quota.Kind) -> Color {
        if let rgb = colors[nameKey(name)] { return Color(hex: rgb) }
        if let key = kindKey(for: kind), let rgb = colors[key] { return Color(hex: rgb) }
        if let rgb = colors[genericKey] { return Color(hex: rgb) }
        return defaultColor(forKind: kind)
    }

    /// 解析 Kimi「总使用量」聚合比例的颜色：overall → generic 回退 → 内置默认。
    static func resolveOverall(_ colors: [String: UInt32]) -> Color {
        if let rgb = colors[overallKey] { return Color(hex: rgb) }
        if let rgb = colors[genericKey] { return Color(hex: rgb) }
        return overallDefault
    }

    /// 判断某个额度窗口是否存在有效的用户配置（解析链与 `resolve` 一致）。
    static func hasConfiguration(_ colors: [String: UInt32], name: String, kind: Quota.Kind) -> Bool {
        if colors[nameKey(name)] != nil { return true }
        if let key = kindKey(for: kind), colors[key] != nil { return true }
        return colors[genericKey] != nil
    }

    /// 判断 Kimi「总使用量」是否存在有效的用户配置（解析链与 `resolveOverall` 一致）。
    static func hasOverallConfiguration(_ colors: [String: UInt32]) -> Bool {
        colors[overallKey] != nil || colors[genericKey] != nil
    }
}

extension Color {
    /// 把颜色量化为不透明的 6 位 sRGB（0xRRGGBB），忽略透明度；无法解析时返回 0。
    var tokenMeterRGB: UInt32 {
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        let red = Int(round(min(max(resolved.redComponent, 0), 1) * 255))
        let green = Int(round(min(max(resolved.greenComponent, 0), 1) * 255))
        let blue = Int(round(min(max(resolved.blueComponent, 0), 1) * 255))
        return UInt32((red << 16) | (green << 8) | blue)
    }
}

struct UsageSnapshot: Identifiable, Codable, Sendable {
    let id: UUID
    let subscriptionID: UUID
    let platform: Platform
    let quotas: [Quota]
    let updatedAt: Date
    let isDemo: Bool
    let errorMessage: String?
    let state: UsageState
    let overallUsageRatio: Double?

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        platform: Platform,
        quotas: [Quota],
        updatedAt: Date,
        isDemo: Bool,
        errorMessage: String?,
        state: UsageState,
        overallUsageRatio: Double? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.platform = platform
        self.quotas = quotas
        self.updatedAt = updatedAt
        self.isDemo = isDemo
        self.errorMessage = errorMessage
        self.state = state
        self.overallUsageRatio = overallUsageRatio
    }

    var overallStatus: QuotaStatus {
        if errorMessage != nil { return .error }
        return status(for: Set(Quota.Kind.allCases))
    }

    func status(for kinds: Set<Quota.Kind>) -> QuotaStatus {
        let selected = quotas.filter { kinds.contains($0.kind) }
        if selected.contains(where: { $0.status == .exhausted }) { return .exhausted }
        if selected.contains(where: { $0.status == .warning }) { return .warning }
        return .normal
    }

    static func realtime(subscription: Subscription, quotas: [Quota], updatedAt: Date = .now, overallUsageRatio: Double? = nil) -> Self {
        .init(
            subscriptionID: subscription.id,
            platform: subscription.platform,
            quotas: quotas,
            updatedAt: updatedAt,
            isDemo: false,
            errorMessage: nil,
            state: .realtime,
            overallUsageRatio: overallUsageRatio
        )
    }

    static func failure(subscription: Subscription, message: String, updatedAt: Date = .now) -> Self {
        .init(subscriptionID: subscription.id, platform: subscription.platform, quotas: [], updatedAt: updatedAt, isDemo: false, errorMessage: message, state: .error)
    }

    static func unsupported(subscription: Subscription, message: String, updatedAt: Date = .now) -> Self {
        .init(subscriptionID: subscription.id, platform: subscription.platform, quotas: [], updatedAt: updatedAt, isDemo: false, errorMessage: message, state: .unsupported)
    }
}

enum UsageState: String, Codable, Sendable {
    case realtime
    case notConfigured
    case authenticationRequired
    case unsupported
    case error

    var label: String {
        switch self {
        case .realtime: "实时数据"
        case .notConfigured: "需要配置"
        case .authenticationRequired: "认证已失效"
        case .unsupported: "接口不支持"
        case .error: "获取错误"
        }
    }

    var tint: SwiftUI.Color {
        switch self {
        case .realtime: .secondary
        case .notConfigured, .authenticationRequired, .unsupported: .orange
        case .error: .red
        }
    }
}

enum Platform: String, CaseIterable, Identifiable, Codable, Sendable {
    case deepSeek = "DeepSeek"
    case zhipu = "智谱 AI"
    case kimi = "Kimi"
    case openCodeGo = "OpenCode Go"
    case miniMax = "MiniMax"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .deepSeek: "bubble.left.and.bubble.right.fill"
        case .zhipu: "sparkles"
        case .kimi: "moon.stars.fill"
        case .openCodeGo: "chevron.left.forwardslash.chevron.right"
        case .miniMax: "cube.fill"
        }
    }

    var capabilityDescription: String {
        switch self {
        case .deepSeek: "支持余额接口，可使用 API Key。"
        case .kimi: "支持 Kimi For Coding 订阅额度、网页登录态和 API Key。"
        case .openCodeGo: "支持用量窗口接口，可使用 API Key。"
        case .zhipu: "支持 GLM Coding Plan 额度窗口（5 小时 / 每周），仅支持 API Key；暂无公开 OAuth 集成。"
        case .miniMax: "支持 MiniMax Coding Plan 套餐额度。"
        }
    }

    var authPageURL: URL? {
        switch self {
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")
        case .kimi: URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .openCodeGo: URL(string: "https://opencode.ai/zen")
        case .zhipu: URL(string: "https://www.bigmodel.cn/usercenter/proj-mgmt/apikeys")
        case .miniMax: URL(string: "https://platform.minimaxi.com/user-center/basic-information/interface-key")
        }
    }
}

enum QuotaStatus: String, Codable, Sendable {
    case normal, warning, exhausted, error

    var label: String {
        switch self {
        case .normal: "正常"
        case .warning: "即将用尽"
        case .exhausted: "已用尽"
        case .error: "获取失败"
        }
    }
}

enum QuotaUnit: Codable, Sendable, Equatable {
    case tokens
    case currency(code: String, scale: Double)

    var isCurrency: Bool {
        if case .currency = self { return true }
        return false
    }

    var label: String? {
        if case .currency(let code, _) = self { return code }
        return nil
    }

    var displayScale: Double {
        if case .currency(_, let scale) = self { return scale }
        return 1
    }
}

struct Quota: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case generic
        case balance
        case fiveHour
        case weekly
    }

    let id: UUID
    let name: String
    let used: Double
    let limit: Double
    let resetAt: Date?
    let unit: QuotaUnit
    let kind: Kind

    init(id: UUID = UUID(), name: String, used: Double, limit: Double, resetAt: Date?, unit: QuotaUnit = .tokens, kind: Kind = .generic) {
        self.id = id
        self.name = name
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
        self.unit = unit
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case id, name, used, limit, resetAt, unit, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        used = try container.decode(Double.self, forKey: .used)
        limit = try container.decode(Double.self, forKey: .limit)
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        unit = try container.decodeIfPresent(QuotaUnit.self, forKey: .unit) ?? .tokens
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .generic
    }

    var remaining: Double {
        kind == .balance ? limit - used : max(0, limit - used)
    }
    var fraction: Double { limit > 0 ? min(max(used / limit, 0), 1) : 0 }
    var status: QuotaStatus {
        if remaining <= 0 { return .exhausted }
        if fraction >= 0.8 { return .warning }
        return .normal
    }

    var usedText: String { Self.format(value: used, unit: unit) }
    var remainingText: String { Self.format(value: remaining, unit: unit) }
    var limitText: String { Self.format(value: limit, unit: unit) }

    private static func format(value: Double, unit: QuotaUnit) -> String {
        let displayValue = value / unit.displayScale
        if let label = unit.label {
            return "\(label) \(String(format: "%.2f", displayValue))"
        }
        if displayValue >= 1_000_000 { return String(format: "%.1fM", displayValue / 1_000_000) }
        if displayValue >= 1_000 { return String(format: "%.1fK", displayValue / 1_000) }
        return String(format: "%.0f", displayValue)
    }
}

extension Date {
    var tokenMeterTimeText: String { formatted(date: .abbreviated, time: .shortened) }
    var tokenMeterResetText: String { formatted(.relative(presentation: .named, unitsStyle: .wide)) }
}
