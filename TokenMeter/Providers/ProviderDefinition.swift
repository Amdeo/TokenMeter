import SwiftUI

// MARK: - 供应商定义

/// 单个供应商的完整定义：元数据、认证方式、用量提供者工厂、Demo 快照与卡片渲染器。
/// 新增供应商时实现本协议并注册到 `ProviderRegistry.all`。
@MainActor
protocol ProviderDefinition: Identifiable {
    var id: ProviderID { get }
    var metadata: ProviderMetadata { get }
    var authMethods: [AuthMethodDefinition] { get }
    var cardRenderer: any ProviderCardRenderer { get }
    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider
    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot
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
