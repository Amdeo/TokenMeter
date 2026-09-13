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

// 供应商的稳定 ID 常量与供应商实现放在一起（`Providers/Extensions/<id>/`），
// 本文件只保留类型。旧数据里的标识 → 稳定 ID 的映射在
// `Providers/Common/LegacyIdentifierMapping.swift`，供应商专有的旧值由各定义声明。

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
    /// 所有 API Key 型供应商共用的认证方式 ID。
    static let apiKey = AuthMethodID(rawValue: "api-key")
}

// MARK: - 认证流程

/// 认证流程的稳定分类，决定编辑页使用哪个 flow 表单与凭据保存逻辑。
enum AuthFlowID: String, Codable, Sendable {
    case apiKey
    case deviceOAuth
    case browserSession
    /// OAuth 授权码（PKCE）：在系统浏览器完成授权后把授权码（或回调地址）粘贴回来。
    case oauthCode
}

/// 设备授权（RFC 8628）：用户在浏览器里输入 userCode 完成确认。
struct DeviceOAuthAuthorization: Sendable {
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
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
    /// 官网首页（编辑页"官网"链接行入口）；无则隐藏。
    var homepageURL: URL? = nil
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
        homepageURL: URL? = nil,
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
        self.homepageURL = homepageURL
        self.authenticationSummary = authenticationSummary
        self.overallUsageLabel = overallUsageLabel
    }
}
