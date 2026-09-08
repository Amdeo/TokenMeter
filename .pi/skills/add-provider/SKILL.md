---
name: add-provider
description: 为 TokenMeter 新增一个 AI 供应商（provider）模块。当用户要求"接入新的 AI 平台 / 添加供应商 / 支持 XX API / 新增厂商"时使用。工作流：确认官方 API 与认证方式 → 新增 provider 定义与 usage provider → 注册到 ProviderRegistry → 选择/实现卡片渲染器 → 添加 fixture 与失败响应测试 → 更新 Xcode 工程与文档 → 本地构建与测试验证。
---

# TokenMeter 新增供应商 Skill

为 TokenMeter（macOS 菜单栏 AI 用量监控）新增一个供应商。架构目标是：
**新增 API Key 供应商时，不修改任何共享 UI、Store 或认证编辑页代码**。

## 0. 先读这些

1. `docs/provider-development.md` — 完整契约（本 Skill 是它的可执行浓缩版）。
2. `TokenMeter/Providers/ProviderRegistry.swift` — 当前注册表。
3. `TokenMeter/Providers/BuiltIn/` — 现有五家 provider 文件（DeepSeek 是最简参考，
   Kimi 是带自定义卡片与多认证的参考）。
4. `TokenMeter/Models/ProviderID.swift` — ProviderID / AuthMethodID / AuthFlowID 定义。

## 1. 确认官方 API

- 找到公开、稳定的用量/余额/额度接口（余额、5 小时/每周窗口、月窗口等）。
- 确认鉴权：`Bearer <key>` 还是裸 key（智谱大陆站用裸 key）。
- 无法确认稳定公开接口时，向用户说明并停在方案阶段，不要伪造。

## 2. 创建 provider 文件

`TokenMeter/Providers/BuiltIn/<Name>Provider.swift`，包含：

```swift
@MainActor
struct <Name>ProviderDefinition: ProviderDefinition {
    let id = ProviderID(rawValue: "<stable-id>")

    var metadata: ProviderMetadata {
        ProviderMetadata(
            displayName: "<显示名>",
            iconResourceName: "icon-<name>",   // 无 PNG 时传 nil
            fallbackSystemImage: "<SF Symbol>",
            tintRGB: 0xRRGGBB,
            capabilityDescription: "<能力说明>",
            authPageURL: URL(string: "<控制台 API Key 页>"),
            authenticationSummary: "API Key · <简述>"
        )
    }

    var authMethods: [AuthMethodDefinition] {
        [AuthMethodDefinition(id: .apiKey, flowID: .apiKey, title: "手动 API Key", systemImage: "key.fill", detail: "适用于所有平台")]
    }

    let cardRenderer: any ProviderCardRenderer = QuotaListCardRenderer()

    func makeUsageProvider(for subscription: Subscription) -> any UsageProvider {
        <Name>UsageProvider(subscription: subscription)
    }

    func makeDemoSnapshot(for subscription: Subscription, now: Date) -> UsageSnapshot {
        .realtime(subscription: subscription, quotas: [
            Quota(name: "<额度名>", used: <数值>, limit: <上限>, resetAt: now.addingTimeInterval(<秒>))
        ])
    }
}
```

`<Name>UsageProvider` 实现 `UsageProvider.fetchUsage()`：
- `credentials.apiKey(for: subscription.id)` 取 key，空则抛 `.notConfigured`。
- 用 `APIClient.get`（数字字符串混用用 `FlexibleNumber`；字段多变用 `JSONValue`
  别名查询）。
- 解析失败抛 `UsageProviderError.invalidResponse`，不要静默返回空。
- 401/403 转 `.authenticationRequired`。

## 3. 注册

在 `ProviderRegistry.all` 追加 `<Name>ProviderDefinition()`。

## 4. 卡片

- 通用额度列表 → `QuotaListCardRenderer()`。
- 某额度窗口优先做顶部摘要 → `QuotaListCardRenderer(anchorHint: "月")`。
- 布局明显不同 → 新建 `<Name>CardRenderer` 实现 `ProviderCardRenderer`
  （参考 `KimiCardRenderer.swift`），在定义中替换 `cardRenderer`。
  特殊数据放 `snapshot.providerData`（Codable JSON 值树），标准卡片不消费它。
- **禁止**在共享 View 中新增按供应商的 `switch`。

## 5. 图标

- PNG 放 `TokenMeter/Resources/PlatformIcons/icon-<name>.png` 并加入 Xcode
  Resources phase；metadata 的 `iconResourceName` 引用它。
- 无 PNG 时 `iconResourceName: nil`，用 `fallbackSystemImage` 兜底。

## 6. 加入 Xcode 工程

`TokenMeter.xcodeproj/project.pbxproj` 四个位置（仿照现有文件条目，ID 用未占用的
`A200000100000000000000XX` / `A100000100000000000000XX` 序列）：

1. `PBXFileReference` 段：文件引用。
2. `PBXBuildFile` 段：编译条目。
3. `PBXGroup` 的 BuiltIn children：加入组。
4. `PBXSourcesBuildPhase` files：加入编译列表。

完成后 `plutil -lint TokenMeter.xcodeproj/project.pbxproj` 必须 OK。

## 7. 测试

在 `TokenMeter/Tests/` 下（新文件则加入 TokenMeterTests target）：
- **解析 fixture**：最小 JSON → decode → 断言额度字段。
- **失败响应**：空/缺字段/非 2xx → 断言抛出对应错误。
- 新增测试文件时同步 pbxproj 的 Tests group / Sources phase。

## 8. 文档

- `README.md` 供应商表加一行（显示名 + 额度类型 + 认证方式）。
- `docs/provider-development.md` 如无特殊情况无需改。

## 9. 验证

```bash
plutil -lint TokenMeter.xcodeproj/project.pbxproj
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

两个都必须通过。完成后报告：变更文件、稳定 ID、认证方式、卡片选择、
测试结果、剩余风险。

## 红线

- 不在共享代码（View / Store / 认证编辑页 / SubscriptionCardPresentation）里
  新增按供应商的 `switch` 或特判。
- 不记录、打印、提交任何 API Key / token / 会话。
- 不伪造接口响应；接口未确认时先问。
- 不跳过失败响应测试。
