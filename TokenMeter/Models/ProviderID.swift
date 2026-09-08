import Foundation

// MARK: - 供应商稳定 ID

/// 供应商稳定标识。后续新增供应商时使用稳定小写短横线命名
/// （如 `anthropic`、`qwen`），存入订阅元数据后不会因显示名变化而失效。
struct ProviderID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ProviderID {
    static let deepSeek = ProviderID(rawValue: "deepseek")
    static let kimi = ProviderID(rawValue: "kimi")
    static let zhipu = ProviderID(rawValue: "zhipu")
    static let openCodeGo = ProviderID(rawValue: "opencode-go")
    static let miniMax = ProviderID(rawValue: "minimax")
    static let ccbus = ProviderID(rawValue: "ccbus")
    static let apikeyFun = ProviderID(rawValue: "apikey-fun")
    static let nowCoding = ProviderID(rawValue: "nowcoding")

    /// 兼容旧 `Platform` 枚举的原始值映射。
    static func legacyPlatformMapping(_ rawValue: String) -> ProviderID {
        switch rawValue {
        case "DeepSeek": .deepSeek
        case "Kimi": .kimi
        case "智谱 AI": .zhipu
        case "OpenCode Go": .openCodeGo
        case "MiniMax": .miniMax
        default: ProviderID(rawValue: rawValue)
        }
    }
}

// MARK: - 认证方式稳定 ID

/// 认证方式稳定标识。`rawValue` 持久化，兼容旧 `Subscription.AuthMethod` 枚举。
struct AuthMethodID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension AuthMethodID {
    static let apiKey = AuthMethodID(rawValue: "api-key")
    static let kimiDeviceOAuth = AuthMethodID(rawValue: "kimi-device-oauth")
    static let kimiBrowserSession = AuthMethodID(rawValue: "kimi-browser-session")
    static let ccbusBrowserSession = AuthMethodID(rawValue: "ccbus-browser-session")
    static let apikeyFunBrowserSession = AuthMethodID(rawValue: "apikey-fun-browser-session")
    static let nowCodingBrowserSession = AuthMethodID(rawValue: "nowcoding-browser-session")

    /// 兼容旧认证枚举值：`manualAPIKey` / `piAuth` / `officialAuth` → api-key，
    /// `kimiOAuth` → kimi-device-oauth，`kimiBrowserSession` → kimi-browser-session。
    static func legacyMapping(_ rawValue: String) -> AuthMethodID {
        switch rawValue {
        case "manualAPIKey", "piAuth", "officialAuth": .apiKey
        case "kimiOAuth": .kimiDeviceOAuth
        case "kimiBrowserSession": .kimiBrowserSession
        default: AuthMethodID(rawValue: rawValue)
        }
    }
}

// MARK: - 认证流程

/// 认证流程的稳定分类，决定编辑页使用哪个 flow 表单与凭据保存逻辑。
enum AuthFlowID: String, Codable, Sendable {
    case apiKey
    case deviceOAuth
    case browserSession
}

/// 供应商支持的认证方式定义（编辑页选项 + 表单驱动）。
struct AuthMethodDefinition: Identifiable, Sendable {
    let id: AuthMethodID
    let flowID: AuthFlowID
    let title: String
    let systemImage: String
    /// 可选的 chip 强调色（0xRRGGBB），缺省使用通用强调色。
    var tintRGB: UInt32?
    let detail: String

    init(id: AuthMethodID, flowID: AuthFlowID, title: String, systemImage: String, tintRGB: UInt32? = nil, detail: String) {
        self.id = id
        self.flowID = flowID
        self.title = title
        self.systemImage = systemImage
        self.tintRGB = tintRGB
        self.detail = detail
    }
}

// MARK: - 供应商元数据

/// 供应商展示层元数据。纯数据、可 Sendable；渲染由 `PlatformLogo` 与选择页读取。
struct ProviderMetadata: Sendable {
    let displayName: String
    /// Bundle 内平台图标资源名（不含扩展名）；nil 时使用 fallbackSystemImage。
    let iconResourceName: String?
    let fallbackSystemImage: String
    /// 主题强调色（0xRRGGBB）。
    let tintRGB: UInt32
    /// 图标内缩比例：部分厂商图标自带留白，需要按比例内缩（如 DeepSeek 0.08）。
    var iconInsetFraction: Double = 0
    let capabilityDescription: String
    /// 供应商控制台 API Key 页面（编辑页"打开浏览器"入口）。
    let authPageURL: URL?
    /// 选择供应商卡片副标题。
    let authenticationSummary: String
    /// 存在「总使用量」聚合额度的供应商（如 Kimi）提供该标签，用于编辑页颜色配置。
    var overallUsageLabel: String? = nil

    init(
        displayName: String,
        iconResourceName: String?,
        fallbackSystemImage: String,
        tintRGB: UInt32,
        iconInsetFraction: Double = 0,
        capabilityDescription: String,
        authPageURL: URL?,
        authenticationSummary: String,
        overallUsageLabel: String? = nil
    ) {
        self.displayName = displayName
        self.iconResourceName = iconResourceName
        self.fallbackSystemImage = fallbackSystemImage
        self.tintRGB = tintRGB
        self.iconInsetFraction = iconInsetFraction
        self.capabilityDescription = capabilityDescription
        self.authPageURL = authPageURL
        self.authenticationSummary = authenticationSummary
        self.overallUsageLabel = overallUsageLabel
    }
}
