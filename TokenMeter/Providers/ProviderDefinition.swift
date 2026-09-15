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
    /// 旧 `Platform` 枚举里的原始值（历史迁移用）；只有经历过那次迁移的供应商需要声明。
    /// 必须作为协议要求声明：仅在扩展里定义的话，`any ProviderDefinition` 会永远拿到默认值。
    var legacyPlatformNames: [String] { get }
}

extension ProviderDefinition {
    /// 旧 `Platform` 枚举里的原始值（历史迁移用）；只有经历过那次迁移的供应商需要声明。
    var legacyPlatformNames: [String] { [] }
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
    /// `deviceOAuth` 流程的设备授权实现；由供应商在自己的目录里声明句柄。
    var deviceAuthorization: DeviceAuthorizationHandler?
    /// `oauthCode` 流程的授权码实现。
    var authorizationCode: AuthorizationCodeHandler?
    /// 旧数据里该认证方式的 ID（历史迁移用）；新供应商不需要声明。
    var legacyIDs: [String] = []

    init(
        id: AuthMethodID,
        flowID: AuthFlowID,
        title: String,
        systemImage: String,
        tintRGB: UInt32? = nil,
        detail: String,
        loginRecipe: BrowserLoginRecipe? = nil,
        deviceAuthorization: DeviceAuthorizationHandler? = nil,
        authorizationCode: AuthorizationCodeHandler? = nil,
        legacyIDs: [String] = []
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
        self.legacyIDs = legacyIDs
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
    /// 整卡渲染：返回非 nil 时卡片完全由供应商渲染（含图标与名称），共享外壳只保留
    /// 点击编辑、悬停、无障碍与排序手柄。图标与名称/数据同排这类布局靠它实现；
    /// 默认 nil，走共享外壳的标准卡片。
    func makeCard(
        definition: any ProviderDefinition,
        subscription: Subscription,
        snapshot: UsageSnapshot
    ) -> AnyView?
    /// 卡片顶部摘要（可为 nil）。
    func summary(subscription: Subscription, snapshot: UsageSnapshot) -> CardSummary?
    /// 卡片状态点/无障碍状态的额度状态派生（realtime 分支）。
    func status(subscription: Subscription, snapshot: UsageSnapshot) -> QuotaStatus
    /// 卡片渲染能力；默认支持进度条，只有一行余额的卡片在自己声明 `.balanceValues`。
    var capabilities: SubscriptionCardCapabilities { get }
    /// 该 renderer 实现了哪些卡片样式；默认只有标准样式。
    /// 在自己目录里实现了紧凑等额外布局的 renderer 在这里声明，样式选择器只列出这些样式。
    var supportedStyles: Set<SubscriptionCardStyle> { get }
    /// 样式预览用的示例快照：与该 renderer 的真实卡片形态一致（余额型只给余额行，窗口型只给窗口行）。
    @MainActor func sampleSnapshot(subscription: Subscription) -> UsageSnapshot
}

@MainActor
extension ProviderCardRenderer {
    var capabilities: SubscriptionCardCapabilities { [.progressMeters] }

    /// 默认只支持标准样式：额外样式需要 renderer 自己实现布局（如 `makeCard` 整卡接管）。
    var supportedStyles: Set<SubscriptionCardStyle> { [.standard] }

    /// 默认不接管整卡：走共享外壳的「图标 + 名称/副标题 + 正文」标准卡片。
    func makeCard(
        definition: any ProviderDefinition,
        subscription: Subscription,
        snapshot: UsageSnapshot
    ) -> AnyView? { nil }

    /// 默认示例：两个窗口额度（5 小时 / 每周），不带总使用量聚合。
    /// 余额型或带聚合锚点的卡片在自己的 renderer 里覆写。
    func sampleSnapshot(subscription: Subscription) -> UsageSnapshot {
        .realtime(
            subscription: subscription,
            quotas: [
                Quota(name: "5 小时额度", used: 62, limit: 100, resetAt: .now.addingTimeInterval(7200), kind: .fiveHour),
                Quota(name: "每周额度", used: 34, limit: 100, resetAt: .now.addingTimeInterval(86400 * 2), kind: .weekly)
            ]
        )
    }
}
