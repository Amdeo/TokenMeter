---
name: add-relay-provider
description: 为 TokenMeter 新增 API 中转站（relay/gateway，如 CCBus、new-api/one-api 系）供应商。当用户只提供一个中转站域名，要求“接入 / 添加 / 支持 xx站余额 / 这个站能加吗”时使用。先用自带脚本起 Chrome 9222 CDP + playwright-cli 探测站点，匹配框架指纹自动识别类型（CCBus 系 / new-api 系等），命中已知框架即直填参数生成模块；未命中再走问答。写 Swift 前先出卡片 HTML 预览（340pt 真面板 + 真实设计令牌，有条/无条共 10 套）并起本地服务让用户看图，同时用提问确认锚点/口径/时间信息/配色/进度表现 5 项。产物是 TokenMeter/Providers/Extensions/<id>/ 下的自有模块加 ProviderCatalog 一行登记。
---

# TokenMeter 中转站供应商 Skill

为 TokenMeter（macOS 菜单栏 AI 用量监控）新增一个 **API 中转站** 供应商。
中转站（AI API 聚合网关）大量使用固定框架，结构高度同构：
**网页登录 → localStorage 存 JWT → 余额接口返回 balance → refresh_token 续期**。

本 Skill 的默认路径是**先探测、再识别、后生成**：用户通常只给一个域名，
AI 用自带脚本起 Chrome 9222 + `playwright-cli attach` 打开站点，匹配下方**框架指纹库**判断站点类型；
命中已知框架就直接用对应模板直填参数生成，无需逐项问答；
未命中才回退到问答收集参数。

最终产物只有两处改动：`TokenMeter/Providers/Extensions/<id>/` 下的新文件夹，
以及 `Providers/Extensions/ProviderCatalog.swift` 里的一行。
`Providers/` 是 Xcode 文件系统同步组，**新增文件不需要改 `project.pbxproj`**。

## 0. 起浏览器 + playwright-cli（探测前置，必做）

探测全部走 CDP，**不依赖 chrome-devtools MCP**。先跑自带脚本：

```bash
bash .pi/skills/add-relay-provider/scripts/chrome-cdp.sh   # 也可用 <skill-dir>/scripts/chrome-cdp.sh
```

脚本行为：

1. `http://127.0.0.1:9222/json/version` 已就绪 → 直接复用，**不改动任何 Chrome 进程**；
2. 否则**先退出正在运行的 Google Chrome**（不退出的话 `open --args` 会被现有进程吞掉、端口永远起不来），
   再以独立 profile 启动调试实例；
3. 20s 内端口不来 → exit 1 并打印 **ACTION REQUIRED** 手动启动命令；
4. 顺带检查 `playwright-cli`，缺失同样 exit 1 并打印安装命令。

**脚本失败时**：把输出里的 ACTION REQUIRED 命令原样转述给用户，让 TA 手动执行，再重跑脚本；
不要自己编 `open -a` 之类别的启动方式（Chrome 136+ 默认 profile 已禁止远程调试，必须带 `--user-data-dir`）。

**playwright-cli 缺失时**：不要静默安装。把 `npm install -g @playwright/cli@latest` 贴给用户，
问一次“要我现在装吗”，得到同意才装；用户不愿意时可退回 chrome-devtools MCP（以 `--browserUrl http://127.0.0.1:9222` 形态连同一端口）。

调试实例是**独立 profile**（`~/Library/Application Support/chrome-cdp-profile`），与用户日常 Chrome 的登录态不共享：
脚本跑通后**先让用户在弹出的调试 Chrome 里登录站点余额页**，再继续探测。
用户不想被打断浏览器时用 `CDP_SKIP_QUIT=1` 跳过退出那一步。
探测结束务必 `playwright-cli -s=relay detach`（只断开，不关用户的浏览器）。

### 探测命令速查（session 统一叫 `relay`）

```text
playwright-cli -s=relay attach --cdp=http://127.0.0.1:9222   # 输出会列出全部标签页与索引
playwright-cli -s=relay tab-select <站点标签页索引>
playwright-cli -s=relay reload                               # 必须重载：requests 只记录 attach 之后的请求
playwright-cli -s=relay requests --filter "/api/"            # 找余额/用户接口的编号
playwright-cli -s=relay response-body <编号>                 # 看响应体（balance / quota）
playwright-cli -s=relay localstorage-list                    # token 键名与值（auth_token / user）
playwright-cli -s=relay cookie-list                          # HttpOnly session cookie 型站点看这里
playwright-cli -s=relay eval "() => Object.keys(localStorage)"
playwright-cli -s=relay detach
```

## 0.5 框架指纹识别（给域名就够）

收到域名后，先按上面的命令探测并判断站点属于哪个已知框架。

### 框架指纹库

| 框架 | 指纹特征 | 判定方法 | 生成模板 |
| --- | --- | --- | --- |
| **CCBus 系**（本项目已实现） | 余额接口 `{api}/auth/me` 返回 `{code:0,data:{balance}}`；localStorage 键 `auth_token` + `refresh_token` + `token_expires_at`；前端请求带 `x-user-ui-request:1` 头 + `?timezone=` 参数 | localStorage 同时存在 `auth_token` 且余额字段是 `data.balance` | 直接照抄 `Extensions/ccbus/CCBusProvider.swift`（含 refresh） |
| **new-api / one-api 系** | 余额接口 `/api/user/self` 返回 `data.quota`（整数，单位需换算）；localStorage 键 `user`（JSON 内 `token` 字段）；通常无 refresh_token；登录态可能是 HttpOnly session cookie | localStorage 存在 `user` 且响应是 `data.quota` | 参照 `Extensions/nowcoding/`（cookie 型）或按 3.3 写自定义 provider |
| 其他/无法识别 | 指纹不匹配 | — | 回退到第 1 节问答 |

### 判定后动作

- **命中 CCBus 系**：直接生成——参数仅需 `域名`（→ 显示名/ID/API 前缀/登录页）、`余额字段 data.balance`、`币种`（默认 USD），其余照抄 CCBus 参照实现。
- **命中 new-api 系**：套用 3.3 的差异点（余额字段 `data.quota` + scale、无 refresh 时直接提示重登），并确认换算 scale（探测响应体或问用户）。
- **未命中**：按第 1 节逐项问答。

> 判断“同一框架”的强信号：localStorage 键名 + 余额字段路径同时吻合。
> 只吻合其一可能是巧合，两条都吻合才可安全直填；否则补一条探测或询问。

### 询问图标（每次生成前都必须问）

探测确认框架后、生成模块之前，**必须询问用户**是否有官方图标：

> 这个站点有官方 logo 吗？可以给我 PNG/SVG 文件或图片 URL；
> 没有的话我会用 SF Symbol 占位，之后可随时补。

- **有**：接收文件路径或 URL，按第 3.5 节处理（下载 → 必要时去背景 → 转 512px → 放进供应商文件夹）。
- **没有/待定**：`iconResourceName: nil`，用 `fallbackSystemImage` 占位，并在完成报告中说明“待补图标”。
- 若平台上明确有 logo 资源（如顶部导航栏 `<img src>`），也可探测页面的 logo URL 主动提议，仍以用户确认为准。

### 卡片样式预览（生成前必做：先出图，再写 Swift）

探测确认接口能力后、写 Swift 之前，**用真实探测数据出一版 HTML 预览给用户看**，
用户点头再动代码——避免做完整套才发现卡片布局不对。

#### ① 必问 4 项（`ask_user_question`，每题 2-4 选项，推荐项放第一）

| # | 维度 | 选项 |
| --- | --- | --- |
| 1 | 锚点内容 | 可用余额 / 主窗口百分比 / 总使用量 / 不显示锚点 |
| 2 | 行内时间信息 | N 天后刷新额度 / 剩 N 天到期 / 状态词「正常」/ 都不显示 |
| 3 | 数值口径 | 百分比 / 金额 / 百分比 + 金额 |
| 4 | 配色来源 | 平台 tint / 状态色（绿 <80%、橙 ≥80%、红 =100%）/ 按额度名自定义 |
| 5 | 进度表现 | 进度条 / 圆点比例 / 纯数值（不要条） |

每题的推荐项按探测结果给（例如只有余额接口 → 锚点默认「不显示」、口径默认「金额」）。

#### ② 填数据段

```bash
mkdir -p /tmp/tokenmeter-card-preview-<id>
cp .pi/skills/add-relay-provider/scripts/card-preview.html /tmp/tokenmeter-card-preview-<id>/index.html
```

**只改文件里的 `window.CARD_DATA = {...}` 数据段，CSS 与渲染逻辑不要动**——
它按 `TM` 令牌与真实 SwiftUI 尺寸写死：340pt 面板 / 卡片圆角 14 / 内边距 11 / 条高 4 / 字号 13·11·10·9。

- `site`：`name` / `subtitle`（`显示名 · 认证方式标题`）/ `icon` / `tint` / `status`（余额偏低 `warning`、用尽 `danger`）
- `variants`：模板自带 10 套——**有条**（① 余额 ② 额度列表 ③ 混合 ④ 订阅分段 ⑤ 总用量锚点）与
  **无条**（⑥ 纯数值行 ⑦ 数值 + 时间提示 ⑧ 单行紧凑表 ⑨ 圆点比例 ⑩ 数值 + 状态徽标）；
  探测做不到的直接删——最终留 3-6 套给用户挑，别把 10 套全堆上去
- 数值一律填**真实探测到的数据**，不要占位符；行类型只有三种：
  `balance{title,value}` / `progress{title,value,percent,state,hints}` / `group{title,hint}`
- `progress` 行的表现力全靠这几个可选字段，用户想要哪种就选哪个：
  `bar: "meter"`（默认进度条）/ `"dots"`（圆点比例，配 `dots: 10`）/ `"none"`（只有数字）
  `inlineHints: true`（时间提示并到同一行，信息密度最高）/ `pill: "正常"` + `pillTint`（状态徽标）
- `tint` 写 `#RRGGBB`，或用 `ok` / `warn` / `danger` 引用状态色
- 有官方图标时把 PNG 复制到同目录，`icon` 写文件名（如 `icon.png`），预览里就能看到真图标

#### ③ 起服务看图

```bash
bash .pi/skills/add-relay-provider/scripts/preview.sh /tmp/tokenmeter-card-preview-<id>
```

用系统自带 `python3 -m http.server`（只绑 `127.0.0.1`，不暴露局域网）+ 自动挑空闲端口 + `open` 浏览器。
改完 HTML 让用户**刷新**即可看到新版；收工 `preview.sh --stop`。
服务起不来时脚本会打印日志路径——把日志贴出来，别自己乱改端口乱重试。

#### ④ 迭代与定稿

用户说「要第③套，但不要状态词」→ 只改数据段（删 `state` 字段）→ 让用户刷新再看，改到点头为止。
定稿后按下表落到 renderer，**不要新造视觉**：

| 选定形态 | Swift 落地 |
| --- | --- |
| ① 余额卡 | `cardRenderer: BalanceCardRenderer()` |
| ② 额度列表卡 | `cardRenderer: QuotaListCardRenderer(anchorHint: "每月窗口")` |
| ③ 混合卡 | 照抄 `Extensions/nowcoding/NowCodingCardRenderer.swift` |
| ④ 订阅分段卡 | 照抄 `Extensions/siyu/SiyuCardRenderer.swift` |
| ⑤ 总用量锚点卡 | 照抄 `Extensions/kimi/KimiCardRenderer.swift` |
| ⑥⑦⑧⑩ 无条数值行 | `BalanceMenuRow`（无提示行时够用）或在 provider 目录里写一个只输出数值的行视图 |
| ⑨ 圆点比例 | provider 目录里自带行视图，把 `MeterBar` 换成一排 6pt 圆点 |

**无进度条形态的硬规矩**：卡片不画条时，renderer 就不要声明 `.progressMeters`
（只声明 `.balanceValues`，或不声明）——编辑页的进度条配色入口与汇总条会自动消失，
因为能力判定要求卡片样式与 renderer **双方**都声明（`ProgressColorSettingsTests` 守着这条）。
想靠“新增一个无条的 `SubscriptionCardStyle`”实现是错的：`everyCardStyleDeclaresProgressMeters` 会直接挂测试。

行组件规矩：`QuotaProgressRow` 自带 `MeterBar`，所以无条形态应当在 **provider 自己的目录**里写行视图，
只允许用 `TM` 令牌、且字号/颜色/间距与标准行保持一致（13·11·10·9 / `textPrimary`·`textSecondary`·`textTertiary`）；
共享组件（`StandardProviderCards.swift`）不改。有进度条的形态一律复用 `BalanceMenuRow` / `QuotaProgressRow`，不要自己重画。
混合卡/分段卡需额外探测订阅接口（如 `/api/subscription/self`）的字段
（`amount_total`/`amount_used`/`end_time`/`next_reset_time`/`plan_title`），
并把订阅映射为 `Quota` 行（`kind: .generic`，`resetAt` 填日重置、`expiresAt` 填到期日）。

## 1. 问答收集参数

向用户提问，收集以下信息。**每项给出推荐默认值**，用户可接受默认或改值。

### 必填

| # | 问题 | 默认值 / 说明 |
| --- | --- | --- |
| 1 | 站点显示名（菜单与卡片显示） | 如 "CCBus（AI 巴士）"，无默认，必填 |
| 2 | 稳定 ID（小写短横线，文件夹名与它一致，发布后不可改） | 从域名派生：`ccbus.top` → `ccbus` |
| 3 | 站点域名（含 https） | 如 `https://ccbus.top`，必填 |
| 4 | 登录页 URL | `{域名}/login`（常见）；若不同请用户提供 |
| 4b | 官网首页 URL（metadata.homepageURL） | 域名根，如 `https://ccbus.top`（编辑页"官网"链接行入口，与登录页/authPageURL 区分）；新建 provider 必须填 |
| 5 | 余额接口路径 | 常见 `{api}/auth/me` 或 `{api}/v1/auth/me`；new-api 系通常 `/api/user/self`。需用户确认或探测 |
| 6 | API 前缀 | `https://ccbus.top/api/v1`（登录/刷新/余额同前缀）；若不同请提供 |

### 探测项（用第 0 节的 playwright-cli 命令自动确认）

| # | 问题 | 说明 |
| --- | --- | --- |
| 7 | localStorage token 键名 | 常见 `auth_token` + `refresh_token`；new-api 系为 `user`（JSON 内 token）或 HttpOnly cookie。用 `localstorage-list`（或 `eval "() => Object.keys(localStorage)"`）确认 |
| 8 | 余额字段路径 | 常见 `data.balance`（`GET /auth/me` 响应 `{code:0,data:{balance}}`）；new-api 系为 `data.quota`（整数，单位需换算） |
| 9 | 余额单位与币种 | 美元 `USD`（默认）或人民币 `CNY`；若为分/厘需 scale（如 new-api quota 单位 500000 ≈ $1） |
| 10 | refresh 端点与请求体 | 常见 `POST {api}/auth/refresh`，body `{"refresh_token": ...}`；无 refresh 时过期直接提示重登 |
| 11 | 是否支持内嵌 WKWebView 登录 | 若站点有 Cloudflare 人机验证/强制验证码，内嵌登录可能失效，改为提示用户"手动在浏览器登录后授权"模式 |

### 可选

| # | 问题 | 默认值 |
| --- | --- | --- |
| 12 | 主题色 tintRGB | `0x2DD4BF`（青绿）或按品牌色 |
| 13 | 官方图标来源（文件路径或 URL） | 无 → 先问；有 → 按 3.5 接入 |
| 14 | SF Symbol 占位图标 | `bus.fill`（无官方图标时用） |
| 15 | 卡片样式（见 0.5 卡片样式可视化） | 按接口能力自动选型后，用 ASCII 预览让用户确认 |

## 2. 探测确认（推荐）

若用户无法回答 7/8/10 项，按下面流程在已登录的调试 Chrome 里确认：

```text
0. bash .pi/skills/add-relay-provider/scripts/chrome-cdp.sh      # 失败就照它的 ACTION REQUIRED 手动执行
1. playwright-cli -s=relay attach --cdp=http://127.0.0.1:9222
2. playwright-cli -s=relay tab-select <站点标签页索引> ; playwright-cli -s=relay reload
3. playwright-cli -s=relay requests --filter "/api/"             # 找到余额/用户接口编号
4. playwright-cli -s=relay response-body <编号>                  # 看响应体字段（balance / quota）
5. playwright-cli -s=relay localstorage-list                     # token 键名；cookie 型站点用 cookie-list
6. playwright-cli -s=relay detach
```

确认后回填参数表。探测只读页面数据，不要 `localstorage-set` / `cookie-set` 写入任何值。

## 3. 生成模块

目标目录：`TokenMeter/Providers/Extensions/<id>/`。
同步组会自动编译这个文件夹里的一切，不需要登记工程文件。

占位符：`<id>` `<域名>` `<API前缀>` `<登录页>` `<显示名>` `<短名>` `<SF Symbol>` `<0xRRGGBB>`。

### 3.1 余额同构的中转站（最省事，一个文件搞定）

新建 `Extensions/<id>/<Name>Provider.swift`，把 ID、站点、续期、定义都写在一起：

```swift
import Foundation

// MARK: - 稳定 ID

extension ProviderID {
    static let <id> = ProviderID(rawValue: "<id>")
}

extension AuthMethodID {
    static let <id>BrowserSession = AuthMethodID(rawValue: "<id>-browser-session")
}

// MARK: - 登录站点

extension BrowserTokenSite {
    static let <id> = BrowserTokenSite(
        displayName: "<短名>",
        loginWindowTitle: "登录 <显示名> 账号",
        accessTokenKey: "<第 7 项确认的键>",          // 常见 auth_token / access_token
        sessionDomains: ["<域名，不含 https>"],
        loginPageURL: URL(string: "<登录页>")!
    )
}

extension BrowserRelayRefresher {
    static let <id> = BrowserRelayRefresher(
        tokenSite: .<id>,
        apiBase: URL(string: "<API前缀，如 https://ccbus.top/api/v1>")!
    )
}

// MARK: - 定义

extension RelayBalanceProviderDefinition {
    static let <id> = RelayBalanceProviderDefinition(
        refresher: .<id>,
        id: .<id>,
        displayName: "<显示名>",
        iconResourceName: nil,                        // 有 PNG 时填 "icon-<id>"
        fallbackSystemImage: "<SF Symbol>",
        tintRGB: <0xRRGGBB>,
        homepageURL: URL(string: "<域名根，如 https://ccbus.top>")!,
        authMethod: AuthMethodDefinition(
            id: .<id>BrowserSession,
            flowID: .browserSession,
            title: "网页登录态",
            systemImage: "globe",
            tintRGB: <0xRRGGBB>,
            detail: "登录 <显示名> 账号（内置）",
            loginRecipe: BrowserTokenSite.<id>.loginRecipe
        )
    )
}
```

- 仅当 refresh token 本身也必须是带 exp 的 JWT 时才加 `validatesRefreshTokenExpiry: true`（目前只有 Kimi）。
- token 存在 `localStorage["user"]` JSON 里或只存在于 HttpOnly cookie（new-api 系）时，走 3.3。

### 3.2 字段不同构时的余额站点

只改「请求哪个路径、取哪个字段、什么币种」的话，写自定义 `UsageProvider`
放进同一个文件夹（参照 `Common/RelayBalanceProvider.swift`），关键骨架：

```swift
struct <Name>UsageProvider: UsageProvider {
    let subscription: Subscription
    private let credentials = CredentialStore()

    func fetchUsage() async throws -> UsageSnapshot {
        guard let stored = credentials.browserCredential(for: subscription.id) else {
            throw UsageProviderError.notConfigured(subscription.providerID)
        }
        let configuration = BrowserSessionFlow.Configuration(
            providerID: subscription.providerID,
            subscriptionID: subscription.id,
            credentials: credentials,
            providerName: BrowserTokenSite.<id>.displayName,
            isUsable: { $0.expiresAt.timeIntervalSinceNow > 300 },
            refresh: { try await BrowserRelayRefresher.<id>.refresh($0) }
        )
        return try await BrowserSessionFlow.fetchWithRetry(
            configuration, stored: stored,
            fetch: { try await fetchBalance(credential: $0) }
        )
    }

    private func fetchBalance(credential: BrowserTokenCredential) async throws -> UsageSnapshot {
        let response: MeResponse = try await APIClient.get(
            BrowserRelayRefresher.<id>.apiBase.appendingPathComponent("<余额路径>"),
            providerID: subscription.providerID,
            authorization: "\(credential.tokenType) \(credential.accessToken)",
            statusPolicy: .raw          // 浏览器会话型必须传，否则刷新重试永不触发
        )
        guard response.code == 0, let data = response.data else {
            throw UsageProviderError.invalidResponse(subscription.providerID, "<显示名> 返回中缺少余额字段")
        }
        return UsageSnapshot.realtime(subscription: subscription, quotas: [
            Quota(name: "可用余额", used: 0, limit: data.balance / <scale>, resetAt: nil,
                  unit: .currency(code: "<币种>", scale: 1), kind: .balance)
        ])
    }
}
```

### 3.3 cookie / 无 refresh 的站点

- **token 在 `localStorage["user"]` 或 HttpOnly cookie（new-api 系）**：
  登录配方用 `.sessionCookie(name:userIDLocalStorageKey:)`，
  参照 `Extensions/nowcoding/NowCodingProvider.swift` 与其中的 `BrowserLoginRecipe.nowCoding`。
- **没有 refresh 端点**：不要 `BrowserRelayRefresher`。
  `refresh:` 直接抛 `UsageProviderError.authenticationRequired(providerID, "登录态已过期，请重新登录")`，
  凭证只能用 cookie/token 直接调业务接口。

### 3.4 登录窗口

无需额外代码：`EmbeddedWebLoginController` 由 `loginRecipe` 统一构造。
务必在 `AuthMethodDefinition` 里带上 `loginRecipe`，
否则编辑页会明确报「该认证方式未声明网页登录配置」，不会退回别的站点。

### 3.5 图标接入（用户提供官方图标时）

1. **获取**：用户给文件 → 直接读取；给 URL → curl 下载到 /tmp。
2. **检查尺寸与背景**：`sips -g pixelWidth -g pixelHeight -g hasAlpha <file>`；
   无 alpha 时用 python 统计角点像素判断背景色（浅色站 logo 常带白/黑底）。
3. **必要去背景**：若为纯色底（白/黑）且非圆角透明图，用 ImageMagick 去掉，
   fuzz 容差保留抗锯齿边缘（黑底 `-fuzz 8% -transparent black`；白底同理 `-transparent white`）。
4. **放大到 512×512**：`magick <src> -resize 512x512 <out>.png`，保留 alpha。
5. **入库**：复制为 `TokenMeter/Providers/Extensions/<id>/icon-<id>.png`（同步组自动收录，无需改工程）。
6. **metadata**：定义里 `iconResourceName: "icon-<id>"`。

> 注意：带纯色底的方形 logo（尤其浅色站）不处理背景就直接入库，
> 会在深色卡片上显示成白块/黑块。判断依据：全图四角同色=纯底需处理；
> 任意角透明或各角颜色不同=图案本身，直接入库。

## 4. 注册与接线

**只有一步**：`TokenMeter/Providers/Extensions/ProviderCatalog.swift` 的
`providers` 数组里加一行（顺序决定 TM-03 的卡片顺序）：

```swift
RelayBalanceProviderDefinition.<id>,
```

**不需要改**（这些地方现在全部由数据驱动，加供应商不该碰）：

- `Models/ProviderID.swift`：ID 常量已挪到供应商自己的文件里。
- `Providers/ProviderRegistry.swift`：`isSupported` / `authFlow` 都从定义派生。
- `Views/SubscriptionEditorSheet.swift`：登录与授权分发读认证方式的声明。
- `Providers/Common/APIClient.swift`：状态码语义由调用方声明。
- `TokenMeter.xcodeproj/project.pbxproj`：`Providers/` 是同步组。

若发现必须改上面任何一处才能接入，那是架构回退，应该先讨论而不是直接改。

## 5. 测试

测试文件放在 `TokenMeter/Tests/`（同样是同步组，新增文件无需登记）。
注册表测试只断言 ID 唯一、命名合法、以及与 `ProviderCatalog` 一致；
新增供应商不必改 `ProviderArchitectureTests.swift`。

按需追加 `@MainActor struct <Name>Tests`：

- 注册表：`ProviderRegistry.definition(for: .<id>)` 非空、authMethods 含
  `<id>-browser-session`、flowID == .browserSession、`loginRecipe` 非空。
- 提取器：有效 JWT payload 构造凭证成功；空 token / 过期 token 抛对应错误。
- 若实现了刷新解析模型：构造响应 JSON → decode 断言字段。

## 6. 验证

```bash
plutil -lint TokenMeter.xcodeproj/project.pbxproj
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

构建与测试必须全部通过。完成后报告：站点名、稳定 ID、余额字段路径、
币种与换算、认证流程（含是否支持 refresh）、测试结果、剩余风险。

## 7. 红线

- 不在共享代码（View / Store / 认证编辑页 / Providers/Common）里新增按供应商的 `switch`。
- 浏览器会话型的 `APIClient` 调用必须传 `statusPolicy: .raw`，
  否则 401/403 会被折叠成「需要重新登录」，刷新重试永远不会发生。
- 登录态提取只读页面 localStorage / cookie；不注入脚本、不上传任何数据。
- 不静默安装 `playwright-cli`（先问用户，同意了才 `npm install -g @playwright/cli@latest`）。
- 浏览器侧只做：跑 `chrome-cdp.sh`、`attach`/`detach`、只读探测。
  不 `localstorage-set` / `cookie-set`，不 `close-all` / `kill-all`，不 `tab-close` 用户的标签页。
- 不记录、打印、提交任何 token / 会话 / 用户数据。
- 不伪造接口响应；余额接口路径与字段未确认时先探测或问用户，不要猜。
- 不跳过失败响应测试。
- 稳定 ID 一经发布不可改（写入用户本地订阅元数据）。
