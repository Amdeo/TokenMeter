import SwiftUI

// MARK: - 供应商定义

/// 单个供应商的完整定义：元数据、认证方式、用量提供者工厂与卡片渲染器。
///
/// 新增供应商时在 `Providers/Extensions/` 下新建模块，并在 `ProviderCatalog` 登记一行。
///
/// 协议本身不做 actor 隔离：`id`、`metadata`、`authMethods` 与 `makeUsageProvider`
/// 都是可跨并发域传递的纯数据，注册表因此能在非隔离上下文里完成 ID 与认证方式查找
/// （凭据迁移等非 UI 路径依赖这一点）。只有 SwiftUI 卡片渲染器是 `@MainActor`，
/// 所以实现方把它写成计算属性——渲染器不是 Sendable，不能作为存储属性留在
/// Sendable 的定义类型里。
protocol ProviderDefinition: Identifiable, Sendable {
    var id: ProviderID { get }
    var metadata: ProviderMetadata { get }
    var authMethods: [AuthMethodDefinition] { get }
    @MainActor var cardRenderer: any ProviderCardRenderer { get }
    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider
}

/// 供应商支持的认证方式定义（编辑页选项 + 表单驱动）。
///
/// 认证方式所需的行为差异全部声明在这里，而不是散在编辑页的 switch 里：
/// `flowID` 决定表单形态，`loginRecipe` 决定内置浏览器登录怎么提取网页登录态凭证，
/// `deviceAuthorization` / `authorizationCode` 决定用哪个授权服务实现。
struct AuthMethodDefinition: Identifiable, Sendable {
    let id: AuthMethodID
    let flowID: AuthFlowID
    let title: String
    let systemImage: String
    /// 可选的 chip 强调色（0xRRGGBB），缺省使用通用强调色。
    var tintRGB: UInt32?
    let detail: String
    /// `browserSession` 流程的登录配方；缺失时编辑页明确报错，不会退回别的站点。
    var loginRecipe: BrowserLoginRecipe?
    /// `deviceOAuth` 流程的设备授权实现。
    var deviceAuthorization: DeviceAuthorizationKind?
    /// `oauthCode` 流程的授权码实现。
    var authorizationCode: AuthorizationCodeKind?

    init(
        id: AuthMethodID,
        flowID: AuthFlowID,
        title: String,
        systemImage: String,
        tintRGB: UInt32? = nil,
        detail: String,
        loginRecipe: BrowserLoginRecipe? = nil,
        deviceAuthorization: DeviceAuthorizationKind? = nil,
        authorizationCode: AuthorizationCodeKind? = nil
    ) {
        self.id = id
        self.flowID = flowID
        self.title = title
        self.systemImage = systemImage
        self.tintRGB = tintRGB
        self.detail = detail
        self.loginRecipe = loginRecipe
        self.deviceAuthorization = deviceAuthorization
        self.authorizationCode = authorizationCode
    }
}

// MARK: - 卡片摘要

/// 订阅卡片顶部「单一数值锚点」的呈现数据。
struct CardSummary: Equatable, Sendable {
    let label: String
    let value: String
    let accessibilityLabel: String
    let colorRGB: UInt32

    init(label: String, value: String, accessibilityLabel: String, colorRGB: UInt32) {
        self.label = label
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.colorRGB = colorRGB
    }
}

// MARK: - 卡片渲染器

/// 供应商卡片正文 + 顶部摘要 + 状态派生的统一契约。
/// 标准渲染器见 `StandardProviderCards.swift`；特殊卡片实现本协议并在定义中替换。
@MainActor
protocol ProviderCardRenderer {
    /// 卡片正文（realtime 状态下显示）。
    func makeBody(subscription: Subscription, snapshot: UsageSnapshot) -> AnyView
    /// 卡片顶部摘要（可为 nil）。
    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary?
    /// 卡片状态点/无障碍状态的额度状态派生（realtime 分支）。
    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus
}
