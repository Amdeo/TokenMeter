# 供应商开发文档 / Provider Development Guide

本文档说明如何为 TokenMeter 新增一个 AI 供应商（provider）。
目标：**新增供应商只需要在 `Providers/Extensions/<id>/` 下加几个文件，
再在 `ProviderCatalog` 加一行**——不改共享 UI、Store、编辑页、HTTP 层，
也不改 `project.pbxproj`。

## 目录

- [架构总览](#架构总览)
- [扩展点：唯一需要动的地方](#扩展点唯一需要动的地方)
- [稳定 ID 命名规则](#稳定-id-命名规则)
- [认证方式与它需要声明的东西](#认证方式与它需要声明的东西)
- [新增余额型中转站（最省事）](#新增余额型中转站最省事)
- [新增 API Key 型供应商](#新增-api-key-型供应商)
- [请求与解析约定](#请求与解析约定)
- [错误分类与 HTTP 状态码策略](#错误分类与-http-状态码策略)
- [凭据与安全](#凭据与安全)
- [卡片：标准 vs 自定义](#卡片标准-vs-自定义)
- [测试要求](#测试要求)
- [提交前检查清单](#提交前检查清单)

---

## 架构总览

```
Providers/
├── ProviderDefinition.swift     协议：元数据 / 认证方式 / 卡片渲染器 / usage provider 工厂
├── ProviderRegistry.swift       注册表门面：目录来自 ProviderCatalog，查找结果全部派生
├── UsageProvider.swift          fetchUsage 协议与统一错误
├── Common/                      共享机制：不认识任何供应商
│   ├── APIClient.swift          HTTP + 由调用方声明的 HTTPStatusPolicy
│   ├── BrowserSessionFlow.swift 「先用手上凭证 → 401/403 刷新一次再重试」
│   ├── BrowserTokenSession.swift 网页登录态类型：BrowserTokenSite / BrowserRelayRefresher / 错误
│   ├── BrowserLoginRecipe.swift 登录配方数据类型与提取实现
│   ├── BrowserCookieCredential.swift cookie 型登录态提取
│   ├── AuthorizationServices.swift 设备授权 / 授权码的实现分派
│   └── RelayBalanceProvider.swift  余额型中转站的通用定义
└── Extensions/                  ← 唯一扩展点（Xcode 文件系统同步组，新增文件零登记）
    ├── ProviderCatalog.swift    唯一手写清单：一行一个供应商
    └── ccbus/ kimi/ zhipu/ …    各供应商一个文件夹
```

复制即用的模板在 `docs/templates/TemplateRelayProvider.swift`，不编进 App。

两个关键约束：

- **共享代码绝不按供应商 switch**。`ProviderRegistry` 的 `isSupported` 与
  `authFlow` 都从 `ProviderDefinition` 自身派生；编辑页的登录与授权分发读取
  认证方式里的声明。共享层里出现供应商名字就是设计错误。
- **`ProviderDefinition` 不做 actor 隔离**（只继承 `Sendable`）。`id`、`metadata`、
  `authMethods` 与 `makeUsageProvider` 都是可跨并发域传递的纯数据，凭据迁移等
  非 UI 路径因此能在不进入主 actor 的情况下查表。唯一的例外是 SwiftUI 卡片渲染器
  `@MainActor var cardRenderer`，实现方必须写成计算属性——渲染器不是 Sendable，
  不能作为存储属性留在 Sendable 的定义里。

## 扩展点：唯一需要动的地方

新增供应商的完整改动：

1. 建一个以稳定 ID 命名的文件夹：`Providers/Extensions/<id>/`。
2. 在里面写供应商模块（可以几个文件：定义、站点常量、自定义卡片、专属服务）。
3. 在 `Providers/Extensions/ProviderCatalog.swift` 的 `providers` 数组里加一行。

`Providers/` 与 `Tests/` 是 Xcode 的 **file-system synchronized group**：
放进目录的 `.swift` 与图标会被自动编译/打包，**不需要改 `project.pbxproj`**。

`ProviderCatalog` 那一行是刻意保留的：Swift 没有可靠的编译期自注册机制，而基于
Objective-C 运行时枚举类的做法会被链接器 dead-strip 掉。一行显式登记可读、可 grep、
可被测试断言。顺序决定 TM-03「选择供应商」页面的卡片顺序。

## 稳定 ID 命名规则

- 使用**小写字母 + 短横线**（如 `deepseek`、`opencode-go`、`anthropic`、`qwen`）。
- 一经发布**不要更改**：它写入用户本地 `subscriptions.json`，改名会丢失订阅关联。
- 文件夹名与稳定 ID 保持一致，一个文件夹就是一个供应商。
- 显示名（`displayName`）可以随时改，与 ID 解耦。
- ID 常量写在供应商自己的文件里，不要再挤进 `Models/ProviderID.swift`：

```swift
extension ProviderID {
    static let anthropic = ProviderID(rawValue: "anthropic")
}

extension AuthMethodID {
    static let anthropicBrowserSession = AuthMethodID(rawValue: "anthropic-browser-session")
}
```

## 认证方式与它需要声明的东西

`AuthFlowID` 决定编辑页用哪种表单；认证方式还要声明该表单运行时需要的行为，
这样编辑页才能不认识具体供应商：

| Flow | 需要额外声明 | 说明 |
| --- | --- | --- |
| `.apiKey` | 无 | API Key 输入框。凭证只存本地私有文件。 |
| `.browserSession` | `loginRecipe` | 内置浏览器登录：域名、登录页、窗口标题、登录态提取方式。 |
| `.deviceOAuth` | `deviceAuthorization` | 设备授权（RFC 8628）用哪个实现（`.kimiCode` / `.codexCode`）。 |
| `.oauthCode` | `authorizationCode` | 授权码（PKCE）用哪个实现（`.claudePKCE`）。 |

**声明缺失会在编辑页显式报错**，不会静默退回别的站点的配置——
这正是以前那个按 `ProviderID` switch 的隐患。`ProviderArchitectureTests` 里有一条
测试遍历所有认证方式，确保每种 flow 都声明齐全。

新增一种**全新协议**（既不是 API Key、网页登录态，也不是现有两种 OAuth）才需要：
在 `AuthFlowID` 加 case、在 `AuthFlowRegistry` 加保存逻辑、在编辑页加表单，
并在 `Providers/Common/` 里加对应的机制分派。这是机制扩展，不是新增供应商。

## 新增余额型中转站（最省事）

中转站大多同构：网页登录 → localStorage 存 JWT → 余额接口 → refresh 续期。
这类只需要一个文件加一行目录登记，可直接复制 `docs/templates/TemplateRelayProvider.swift`。

```swift
// Providers/Extensions/my-relay/MyRelayProvider.swift

extension ProviderID {
    static let myRelay = ProviderID(rawValue: "my-relay")
}

extension AuthMethodID {
    static let myRelayBrowserSession = AuthMethodID(rawValue: "my-relay-browser-session")
}

extension BrowserTokenSite {
    static let myRelay = BrowserTokenSite(
        displayName: "MyRelay",                       // 错误文案里的短名
        loginWindowTitle: "登录 MyRelay 账号",
        accessTokenKey: "auth_token",                 // DevTools 里看 localStorage 键名
        sessionDomains: ["myrelay.example"],
        loginPageURL: URL(string: "https://myrelay.example/login")!
    )
}

extension BrowserRelayRefresher {
    static let myRelay = BrowserRelayRefresher(
        tokenSite: .myRelay, apiBase: URL(string: "https://myrelay.example/api/v1")!
    )
}

extension RelayBalanceProviderDefinition {
    static let myRelay = RelayBalanceProviderDefinition(
        refresher: .myRelay, id: .myRelay, displayName: "MyRelay",
        iconResourceName: nil,                        // PNG 放本文件夹即可
        fallbackSystemImage: "bolt.fill",
        tintRGB: 0x2DD4BF,
        homepageURL: URL(string: "https://myrelay.example")!,
        authMethod: AuthMethodDefinition(
            id: .myRelayBrowserSession, flowID: .browserSession,
            title: "网页登录态", systemImage: "globe", tintRGB: 0x2DD4BF,
            detail: "登录 MyRelay 账号（内置）",
            loginRecipe: BrowserTokenSite.myRelay.loginRecipe
        )
    )
}
```

余额不在 `{apiBase}/auth/me` 的 `data.balance`、或需要额度窗口时，别用通用定义，
仿照 `Common/RelayBalanceProvider.swift` 写自己的 `ProviderDefinition` 与
`UsageProvider`，放进同一个文件夹。

站点不提供续期（token 过期只能重新登录）时不要 `BrowserRelayRefresher`，
`BrowserSessionFlow.Configuration` 的 `refresh:` 直接抛
`UsageProviderError.authenticationRequired(providerID, "登录态已过期，请重新登录")`。

## 新增 API Key 型供应商

1. 在 `Providers/Extensions/<id>/` 新建一个文件，实现两个类型：
   - `<Name>ProviderDefinition: ProviderDefinition`：`id`、`metadata`、`authMethods`、
     `cardRenderer`（计算属性）、`makeUsageProvider(for:)`。
   - `<Name>UsageProvider: UsageProvider`：`fetchUsage()` 与响应类型。
2. 需要额度进度条时 `cardRenderer` 用 `QuotaListCardRenderer()`；
   只有余额用 `BalanceCardRenderer()`。
3. 在 `ProviderCatalog.providers` 加一行。

参考实现：`Extensions/zhipu/ZhipuProvider.swift`（条件分支较多的额度窗口）、
`Extensions/minimax/MiniMaxProvider.swift`（数组映射为多行额度）。

## 请求与解析约定

- 复用 `APIClient.get/post`（统一日志、状态码分类、可注入传输层便于测试）。
- 数字可能以字符串返回时，用 `FlexibleNumber`。
- 字段命名多变时，用 `JSONValue` 的别名查询（`number(for:)` / `string(for:)` /
  `findObject(for:)`），键名做小写字母数字归一化。
- 解析失败抛 `UsageProviderError.invalidResponse(providerID, "说明")`，
  不要静默返回空快照。

## 错误分类与 HTTP 状态码策略

`UsageStore` 依据 `UsageProviderError` 生成快照状态：

| Error | 快照状态 | 卡片表现 |
| --- | --- | --- |
| `.notConfigured` | `notConfigured` | 需要配置 |
| `.authenticationRequired` | `authenticationRequired` | 认证已失效 |
| `.unsupported` | `unsupported` | 暂不支持额度接口 |
| `.invalidResponse` / `.httpStatus` / `.requestFailed` / `.invalidJSON` | `error` | 获取失败 |

**共享 HTTP 层不认识供应商**：401/403 的含义由调用方声明的 `HTTPStatusPolicy` 决定。

- API Key 型：不传（默认 `.invalidCredential`），401/403 直接呈现为凭证失效。
- **浏览器会话型与 OAuth 型必须传 `.raw`**，否则 `BrowserSessionFlow` 的
  「刷新一次再重试」永远不会触发，用户会莫名其妙被要求重新登录。
- 供应商专有的状态码文案（如余额不足 402、限流 429）写在自己的
  `HTTPStatusPolicy(messages:)` 里，不要加进共享层。

## 凭据与安全

- 凭据只保存在 `~/Library/Application Support/TokenMeter/credentials.json`
  （目录 0o700、文件 0o600），**绝不写入订阅元数据**。
- 通过 `CredentialStore` 存取；API Key 型用 `credentials.apiKey(for:)`。
- 不要记录、打印或提交任何 API Key / token。日志只写 provider ID 与状态码。
- 网页登录态提取只读取页面 localStorage / cookie，不注入、不上传。

## 卡片：标准 vs 自定义

标准渲染器（`Views/ProviderCards/StandardProviderCards.swift`）：

| Renderer | 适用 | 行为 |
| --- | --- | --- |
| `BalanceCardRenderer` | 只有余额、无进度条 | 单行余额，无顶部摘要 |
| `QuotaListCardRenderer` | 通用额度列表 | 顶部摘要取第一个额度（或 `anchorHint` 命中的），正文列出其余 |
| `UnsupportedCardRenderer` | 未知/失效供应商 | 降级提示 |

布局与标准渲染器明显不同时才实现自定义 `ProviderCardRenderer`
（参考 `Extensions/kimi/KimiCardRenderer.swift`、`Extensions/siyu/SiyuCardRenderer.swift`），
把文件放在该供应商自己的文件夹里，并在定义中替换 `cardRenderer`。
自定义卡片可通过 `snapshot.providerData`（Codable JSON 值树）读取自己命名空间的字段。

## 测试要求

测试文件放在 `TokenMeter/Tests/`（同样是同步组，新增文件无需登记）。

- 每个供应商至少一个**解析 fixture 测试**：最小 JSON 响应 → decode → 断言额度字段。
- 至少一个**失败响应测试**：空数据 / 缺字段 / 非 2xx → 断言抛出对应
  `UsageProviderError`。
- 注册表测试（`ProviderArchitectureTests.swift`）覆盖：ID 唯一且符合命名规则、
  metadata 完整、authMethods 正确、每种 flow 的声明齐全、factory 可用。
  新增供应商不必改这份测试。
- 本地验证：

```bash
plutil -lint TokenMeter.xcodeproj/project.pbxproj
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

## 提交前检查清单

- [ ] 稳定 ID 命名正确、不与现有冲突，且与文件夹名一致
- [ ] 所有改动都在 `Providers/Extensions/<id>/` 内（加上 `ProviderCatalog` 一行）
- [ ] 图标放进了供应商文件夹，或确认 fallback SF Symbol 可用
- [ ] 浏览器会话型 provider 的 `APIClient` 调用传了 `statusPolicy: .raw`
- [ ] 解析 fixture 测试 + 失败响应测试通过
- [ ] 未在共享代码（View / Store / 编辑页 / Support）中新增按供应商的 `switch`
- [ ] 未记录/提交任何凭据，凭据只走 `CredentialStore`
