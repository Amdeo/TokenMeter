import Foundation
import AppKit
import SwiftUI

// MARK: - 卡片样式

/// 菜单栏订阅卡片的展示样式。持久化在订阅上，缺失时回退标准样式。
enum SubscriptionCardStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case compact
    case hero

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "标准"
        case .compact: "紧凑"
        case .hero: "醒目"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: "名称 + 摘要 + 完整额度行"
        case .compact: "只保留名称与一条总览进度"
        case .hero: "突出显示关键数值"
        }
    }
}

extension SubscriptionCardStyle {
    /// 该样式在卡片里渲染的进度条能力。三种现有样式都会画进度条（紧凑样式画一条汇总条）；
    /// 未来新增「不含进度条」的样式时在这里返回空集合，颜色设置入口会自动消失。
    var capabilities: SubscriptionCardCapabilities { [.progressMeters] }
}

/// 订阅卡片的渲染能力声明。
///
/// 能力由两处共同声明，共享 UI（如颜色设置）据此决定是否提供对应配置：
/// - `SubscriptionCardStyle.capabilities`：该样式画不画进度条；
/// - `ProviderCardRenderer.capabilities`：该供应商卡片的数据有没有进度条
///   （如余额型卡片只有一行余额，但它声明 `.balanceValues`，余额数值仍可配颜色）。
///
/// 新增不含进度条的卡片样式或供应商卡片时只需一处不声明 `.progressMeters`，
/// 不需要在共享视图里按供应商写分支。
struct SubscriptionCardCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// 卡片渲染进度条（含紧凑样式的汇总进度条）。
    static let progressMeters = SubscriptionCardCapabilities(rawValue: 1 << 0)

    /// 卡片渲染余额数值（正文余额行或头部余额锚点）；颜色设置据此提供余额颜色目标。
    static let balanceValues = SubscriptionCardCapabilities(rawValue: 1 << 1)

    /// 卡片真正渲染出进度条：样式与供应商 renderer 都必须声明该能力。
    /// 颜色设置入口与紧凑样式的汇总条共用这一判定，两者不会各自脱节。
    static func renderProgressMeters(
        style: SubscriptionCardCapabilities,
        renderer: SubscriptionCardCapabilities
    ) -> Bool {
        style.contains(.progressMeters) && renderer.contains(.progressMeters)
    }
}

/// 订阅的进度条配色：按卡片样式隔离。
///
/// 同一订阅可以为「标准 / 紧凑 / 醒目」各配一套颜色，切换样式后各自的配色保留、互不覆盖；
/// 卡片渲染、摘要锚点与颜色编辑页都只读当前样式的那一份。
struct SubscriptionQuotaPalette: Codable, Hashable, Sendable {
    /// 外层键为样式 rawValue；用字符串存键，未来新增样式的配色也能原样往返。
    private var byStyle: [String: [String: UInt32]]

    init() { byStyle = [:] }

    /// 单一颜色字典 → 标准样式的配色：旧数据迁移（旧版本只有一份配色，没有样式隔离）的入口。
    init(standard: [String: UInt32]) {
        byStyle = standard.isEmpty ? [:] : [SubscriptionCardStyle.standard.rawValue: standard]
    }

    /// 单个样式的配色；未配置的样式返回空表。写入空表等于清除该项，避免落下空对象。
    subscript(style: SubscriptionCardStyle) -> [String: UInt32] {
        get { byStyle[style.rawValue] ?? [:] }
        set { byStyle[style.rawValue] = newValue.isEmpty ? nil : newValue }
    }

    var isEmpty: Bool { byStyle.isEmpty }

    init(from decoder: Decoder) throws {
        byStyle = try decoder.singleValueContainer().decode([String: [String: UInt32]].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(byStyle)
    }
}

struct Subscription: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let providerID: ProviderID
    var name: String
    var authMethodID: AuthMethodID
    let createdAt: Date
    var isEnabled: Bool
    /// 进度条配色，按卡片样式隔离、按额度标识寻址（名称 / 语义类型 / 默认项）。
    /// 只有声明了进度条能力的卡片会读取与展示它。
    var quotaColors: SubscriptionQuotaPalette
    var cardStyle: SubscriptionCardStyle

    init(
        id: UUID = UUID(),
        providerID: ProviderID,
        name: String,
        authMethodID: AuthMethodID = .apiKey,
        createdAt: Date = .now,
        isEnabled: Bool = true,
        quotaColors: SubscriptionQuotaPalette = SubscriptionQuotaPalette(),
        cardStyle: SubscriptionCardStyle = .standard
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.authMethodID = authMethodID
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.quotaColors = quotaColors
        self.cardStyle = cardStyle
    }

    /// 兼容旧数据的解码：优先读新字段 providerID/authMethodID，缺失时回退旧 platform/authMethod。
    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, isEnabled, quotaColors, cardStyle
        case providerID
        case authMethodID
        case platform
        case authMethod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let providerID = try container.decodeIfPresent(ProviderID.self, forKey: .providerID) {
            self.providerID = providerID
        } else {
            let legacy = try container.decode(String.self, forKey: .platform)
            self.providerID = ProviderID.legacyPlatformMapping(legacy)
        }
        name = try container.decode(String.self, forKey: .name)
        if let authMethodID = try container.decodeIfPresent(AuthMethodID.self, forKey: .authMethodID) {
            self.authMethodID = authMethodID
        } else {
            let legacy = try container.decode(String.self, forKey: .authMethod)
            self.authMethodID = AuthMethodID.legacyMapping(legacy)
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // 新格式是按样式隔离的配色表；旧的单一颜色字典解码时迁移到标准样式，不丢数据。
        if let palette = try? container.decode(SubscriptionQuotaPalette.self, forKey: .quotaColors) {
            quotaColors = palette
        } else {
            quotaColors = SubscriptionQuotaPalette(
                standard: try container.decodeIfPresent([String: UInt32].self, forKey: .quotaColors) ?? [:]
            )
        }
        cardStyle = try container.decodeIfPresent(SubscriptionCardStyle.self, forKey: .cardStyle) ?? .standard
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(name, forKey: .name)
        try container.encode(authMethodID, forKey: .authMethodID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(quotaColors, forKey: .quotaColors)
        try container.encode(cardStyle, forKey: .cardStyle)
    }
}

extension Subscription {
    /// 当前卡片样式对应的配色：卡片渲染、摘要锚点与编辑流程都读写这一份。
    var currentQuotaColors: [String: UInt32] {
        get { quotaColors[cardStyle] }
        set { quotaColors[cardStyle] = newValue }
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
    /// 余额数值的语义键（正文余额行与头部余额锚点共用）。
    static let balanceKey = "kind.balance"

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
        case .balance: balanceKey
        case .generic: nil
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
    let providerID: ProviderID
    let quotas: [Quota]
    let updatedAt: Date
    let errorMessage: String?
    let state: UsageState
    let overallUsageRatio: Double?
    /// 「总使用量」聚合额度的重置时间（如 Kimi 订阅月额度的重置日）。
    let overallResetAt: Date?
    /// 供应商可选的额外数据（Codable JSON 值树），供自定义卡片 renderer 消费。
    let providerData: JSONValue?

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        providerID: ProviderID,
        quotas: [Quota],
        updatedAt: Date,
        errorMessage: String?,
        state: UsageState,
        overallUsageRatio: Double? = nil,
        overallResetAt: Date? = nil,
        providerData: JSONValue? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.providerID = providerID
        self.quotas = quotas
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.state = state
        self.overallUsageRatio = overallUsageRatio
        self.overallResetAt = overallResetAt
        self.providerData = providerData
    }

    enum CodingKeys: String, CodingKey {
        case id, subscriptionID, quotas, updatedAt, errorMessage, state, overallUsageRatio, overallResetAt
        case providerID
        case providerData
        case platform
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subscriptionID = try container.decode(UUID.self, forKey: .subscriptionID)
        if let providerID = try container.decodeIfPresent(ProviderID.self, forKey: .providerID) {
            self.providerID = providerID
        } else {
            let legacy = try container.decode(String.self, forKey: .platform)
            self.providerID = ProviderID.legacyPlatformMapping(legacy)
        }
        quotas = try container.decode([Quota].self, forKey: .quotas)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        state = try container.decode(UsageState.self, forKey: .state)
        overallUsageRatio = try container.decodeIfPresent(Double.self, forKey: .overallUsageRatio)
        overallResetAt = try container.decodeIfPresent(Date.self, forKey: .overallResetAt)
        providerData = try container.decodeIfPresent(JSONValue.self, forKey: .providerData)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(subscriptionID, forKey: .subscriptionID)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(quotas, forKey: .quotas)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(errorMessage, forKey: .errorMessage)
        try container.encode(state, forKey: .state)
        try container.encode(overallUsageRatio, forKey: .overallUsageRatio)
        try container.encode(overallResetAt, forKey: .overallResetAt)
        try container.encode(providerData, forKey: .providerData)
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

    static func realtime(
        subscription: Subscription,
        quotas: [Quota],
        updatedAt: Date = .now,
        overallUsageRatio: Double? = nil,
        overallResetAt: Date? = nil,
        providerData: JSONValue? = nil
    ) -> Self {
        .init(
            subscriptionID: subscription.id,
            providerID: subscription.providerID,
            quotas: quotas,
            updatedAt: updatedAt,
            errorMessage: nil,
            state: .realtime,
            overallUsageRatio: overallUsageRatio,
            overallResetAt: overallResetAt,
            providerData: providerData
        )
    }

    static func failure(subscription: Subscription, message: String, updatedAt: Date = .now) -> Self {
        .init(subscriptionID: subscription.id, providerID: subscription.providerID, quotas: [], updatedAt: updatedAt, errorMessage: message, state: .error)
    }

    static func unsupported(subscription: Subscription, message: String, updatedAt: Date = .now) -> Self {
        .init(subscriptionID: subscription.id, providerID: subscription.providerID, quotas: [], updatedAt: updatedAt, errorMessage: message, state: .unsupported)
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

    /// 额度行的分组元数据：同一分组（如一个订阅套餐的每日/每周/每月窗口）在卡片中归入同一段落。
    /// `key` 只在单个快照内唯一；`title` 是段落标题。显示名可能重复
    /// （如服务端没给套餐信息时的兜底名），因此不能拿 `name` 当分组身份。
    struct Group: Codable, Sendable, Hashable {
        let key: String
        let title: String
    }

    let id: UUID
    let name: String
    let used: Double
    let limit: Double
    let resetAt: Date?
    /// 额度/订阅的到期时间（区别于每日重置），如订阅到期日。nil 表示无到期概念。
    let expiresAt: Date?
    let unit: QuotaUnit
    let kind: Kind
    let group: Group?

    init(id: UUID = UUID(), name: String, used: Double, limit: Double, resetAt: Date?, expiresAt: Date? = nil, unit: QuotaUnit = .tokens, kind: Kind = .generic, group: Group? = nil) {
        self.id = id
        self.name = name
        self.used = used
        self.limit = limit
        self.resetAt = resetAt
        self.expiresAt = expiresAt
        self.unit = unit
        self.kind = kind
        self.group = group
    }

    enum CodingKeys: String, CodingKey {
        case id, name, used, limit, resetAt, expiresAt, unit, kind, group
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        used = try container.decode(Double.self, forKey: .used)
        limit = try container.decode(Double.self, forKey: .limit)
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        unit = try container.decodeIfPresent(QuotaUnit.self, forKey: .unit) ?? .tokens
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .generic
        group = try container.decodeIfPresent(Group.self, forKey: .group)
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
