# 供应商开发文档 / Provider Development Guide

本文档说明如何为 TokenMeter 新增一个 AI 供应商（provider）。目标：**新增一个 API Key 供应商时，不需要修改任何共享 UI、Store 或认证编辑页代码**；只需新增 provider 模块、注册定义、图标、demo 与测试。

This guide explains how to add a new AI provider to TokenMeter. Goal: **adding an
API-Key provider requires no changes to shared UI, Store, or the auth editor** —
just a new provider module, a registry entry, an icon, demo data, and tests.

## 目录 / Table of Contents

- [架构总览 / Architecture overview](#架构总览--architecture-overview)
- [稳定 ID 命名规则 / Stable ID naming](#稳定-id-命名规则--stable-id-naming)
- [认证方式选择 / Choosing an auth method](#认证方式选择--choosing-an-auth-method)
- [新增 API Key 供应商（标准流程） / Adding an API-Key provider (standard flow)](#新增-api-key-供应商标准流程--adding-an-api-key-provider-standard-flow)
- [请求与解析约定 / Request & parsing conventions](#请求与解析约定--request--parsing-conventions)
- [错误分类 / Error classification](#错误分类--error-classification)
- [凭据与安全 / Credentials & security](#凭据与安全--credentials--security)
- [卡片：标准 vs 自定义 / Cards: standard vs custom](#卡片标准-vs-自定义--cards-standard-vs-custom)
- [Demo 数据与图标 / Demo data & icons](#demo-数据与图标--demo-data--icons)
- [测试要求 / Testing requirements](#测试要求--testing-requirements)
- [提交前检查清单 / Pre-submit checklist](#提交前检查清单--pre-submit-checklist)

---

## 架构总览 / Architecture overview

```
ProviderRegistry.all                ← 唯一的供应商目录（编译期）
   │  definition(for: ProviderID)
   ▼
ProviderDefinition                  ← 每家供应商一份定义
   ├─ metadata: ProviderMetadata    ← 显示名 / 图标 / 颜色 / 能力说明 / 控制台链接
   ├─ authMethods: [AuthMethodDefinition] ← 支持的认证方式（flow 由 AuthFlowID 决定）
   ├─ cardRenderer: ProviderCardRenderer  ← 卡片正文 / 摘要 / 状态
   ├─ makeUsageProvider(for:)       ← 生产 provider（fetch 实现）
   └─ makeDemoSnapshot(for:now:)    ← Debug 预览数据
```

- **共享代码绝不按供应商 `switch`**：`SubscriptionUsageView`、`MenuBarView`、
  `SubscriptionEditorSheet`、`UsageStore` 都只依赖 `ProviderRegistry` /
  `ProviderDefinition`。
- `Subscription` 与 `UsageSnapshot` 持久化 `ProviderID`（稳定小写字符串），
  旧数据的 `platform` / `authMethod` 字段自动迁移，用户无需重新添加订阅。

## 稳定 ID 命名规则 / Stable ID naming

- 使用**小写字母 + 短横线**（如 `deepseek`、`opencode-go`、`anthropic`、`qwen`）。
- 一经发布**不要更改**：它写入用户本地 `subscriptions.json`，改名会丢失订阅关联。
- 显示名（`displayName`）可以随时改，与 ID 解耦。

```swift
extension ProviderID {
    static let anthropic = ProviderID(rawValue: "anthropic")
}
```

## 认证方式选择 / Choosing an auth method

`AuthFlowID` 决定编辑页表单与凭据存储方式：

| Flow | 说明 / When to use |
| --- | --- |
| `.apiKey` | 供应商提供 API Key（绝大多数情况）。凭证存本地私有文件，只发到该供应商官方 API。 |
| `.deviceOAuth` | 供应商支持 Device Authorization Grant（如 Kimi Code OAuth）。需要在 `AuthFlowRegistry` 与编辑页接入授权服务与轮询。 |
| `.browserSession` | 需要网页登录态（如 Kimi 浏览器会话）。需要内嵌登录与刷新逻辑。 |

新增供应商默认选择 `.apiKey`。新增不同 OAuth 协议时才需要扩展认证 flow；
那是少数情况，且应在 `AuthFlowRegistry` 中新增 handler，不要修改编辑页的共享逻辑。

## 新增 API Key 供应商（标准流程）/ Adding an API-Key provider (standard flow)

1. **确认官方 API**：找到公开、稳定的用量/余额/额度接口，确认鉴权方式（`Bearer` 或裸 key）。
2. **新增 provider 文件** `TokenMeter/Providers/BuiltIn/<Name>Provider.swift`，
   包含：
   - `<Name>ProviderDefinition: ProviderDefinition`（metadata、authMethods、cardRenderer、两个 factory）
   - `<Name>UsageProvider: UsageProvider`（`fetchUsage()` 实现 + 响应类型）
3. **注册**：在 `ProviderRegistry.all` 追加一条定义。
4. **图标**：放 `TokenMeter/Resources/PlatformIcons/icon-<name>.png`，并在
   metadata 的 `iconResourceName` 引用；同时加入 Xcode 工程的 Resources phase。
5. **加入 Xcode target**：新 Swift 文件加入 `TokenMeter` target
   （`TokenMeter.xcodeproj/project.pbxproj`：PBXBuildFile / PBXFileReference /
   PBXGroup / PBXSourcesBuildPhase）。
6. **Demo 数据**：实现 `makeDemoSnapshot`（真实字段样例，供 Debug 预览）。
7. **测试**：至少一个解析 fixture 测试 + 一个注册表测试（见下文）。
8. **文档**：更新 README 的供应商表与本文档（如有特殊卡片）。

新增一个 API Key 供应商的改动集中在**一个文件 + 注册行 + 图标 + 测试**。

## 请求与解析约定 / Request & parsing conventions

- 复用 `APIClient.get/post`（统一日志、HTTP 状态码分类与超时处理）。
- 数字可能以字符串返回时，用 `FlexibleNumber` 字段类型。
- 字段命名多变时，用 `JSONValue` 的别名查询（`number(for:)` / `string(for:)` /
  `findObject(for:)`），键名做小写字母数字归一化。
- 响应解析失败时抛出 `UsageProviderError.invalidResponse(providerID, "说明")`，
  不要静默返回空快照。

```swift
struct MyProviderUsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let key = credentials.apiKey(for: subscription.id), !key.isEmpty else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let root: JSONValue = try await APIClient.get(
            URL(string: "https://api.example.com/v1/usage")!,
            providerID: subscription.providerID,
            authorization: "Bearer \(key)"
        )
        guard let used = root.number(for: ["used", "usage"]),
              let limit = root.number(for: ["limit", "total"]), limit > 0 else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "缺少 used/limit")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "用量", used: used, limit: limit, resetAt: root.resetDate)
        ])
    }
}
```

## 错误分类 / Error classification

统一通过 `UsageProviderError`，`UsageStore` 据此生成不同快照状态：

| Error | 快照状态 | 卡片表现 |
| --- | --- | --- |
| `.notConfigured` | `notConfigured` | 需要配置 |
| `.authenticationRequired` | `authenticationRequired` | 认证已失效 |
| `.unsupported` | `unsupported` | 暂不支持额度接口 |
| `.invalidResponse` / `.httpStatus` / `.requestFailed` / `.invalidJSON` | `error` | 获取失败 |

HTTP 401/403 应转成 `.authenticationRequired`（在 APIClient 的默认分支之外按需补充）。

## 凭据与安全 / Credentials & security

- 所有凭据只保存在 `~/Library/Application Support/TokenMeter/credentials.json`
  （目录 0o700、文件 0o600），**绝不写入订阅元数据**。
- 通过 `CredentialStore.credential(for:flowID:)` / `save(_:for:)` 存取；
  API Key 供应商用 `credentials.apiKey(for:)` 即可。
- 不要记录、打印或提交任何 API Key / token。日志只写 provider ID 与状态码。
- `kimi-export-session*.md` 等可能含敏感信息的调试导出已被 `.gitignore` 排除，勿提交。

## 卡片：标准 vs 自定义 / Cards: standard vs custom

标准渲染器（`Views/ProviderCards/StandardProviderCards.swift`）：

| Renderer | 适用 / Use when | 行为 |
| --- | --- | --- |
| `BalanceCardRenderer` | 只有余额、无进度条 | 单行余额，无顶部摘要 |
| `QuotaListCardRenderer` | 通用额度列表 | 顶部摘要取第一个额度（或 `anchorHint` 命中的额度），正文列出其余 |
| `UnsupportedCardRenderer` | 未知/失效供应商 | 降级提示 |

- **通用额度列表**：定义里用 `QuotaListCardRenderer()`。
- **某个额度窗口优先做顶部摘要**（如 OpenCode Go 的「每月窗口」）：
  `QuotaListCardRenderer(anchorHint: "月")`。
- **布局与默认渲染器明显不同**：实现自定义 `ProviderCardRenderer`
  （参考 `KimiCardRenderer.swift`），在定义中替换 `cardRenderer`。
  自定义卡片可通过 `snapshot.providerData`（Codable JSON 值树）读取自己命名空间的字段；
  标准卡片不消费它。

## Demo 数据与图标 / Demo data & icons

- `makeDemoSnapshot` 返回结构真实的样例快照（Debug「预览状态」使用），
  数值不必精确，但要包含该供应商真实的额度名称与 kind。
- 图标放到 `Resources/PlatformIcons/`，在 Xcode Resources phase 注册；
  无 PNG 时用 `fallbackSystemImage`（SF Symbol）兜底。

## 测试要求 / Testing requirements

- 每个供应商至少一个 **解析 fixture 测试**：构造最小 JSON 响应 → decode →
  断言额度字段（参考现有 Kimi/Zhipu 测试）。
- 至少一个 **失败响应测试**：空数据 / 缺字段 / 非 2xx → 断言抛出对应
  `UsageProviderError`。
- 注册表测试覆盖：ID 唯一、metadata 完整、authMethods 正确、factory 可用
  （见 `ProviderArchitectureTests.swift`）。
- 用 `xcodebuild ... test CODE_SIGNING_ALLOWED=NO` 本地验证。

## 提交前检查清单 / Pre-submit checklist

- [ ] 稳定 ID 命名正确且不与现有冲突
- [ ] 新文件已加入 Xcode target（编译 + 测试通过）
- [ ] 图标已注册，或确认 fallback symbol 可用
- [ ] 解析 fixture 测试 + 失败响应测试通过
- [ ] README 供应商表已更新
- [ ] 未在共享代码（View / Store / 编辑页）中新增按供应商的 `switch`
- [ ] 未记录/提交任何凭据，凭据只走 CredentialStore
