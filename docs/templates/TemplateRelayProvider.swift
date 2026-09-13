import Foundation

//  ██  新增供应商模板  ██
//
//  这个文件是「余额型中转站」模板，放在 docs/ 下，不编进 App。
//  复制到 `Providers/Extensions/<id>/`、改名、填参数，
//  再在 `Providers/Extensions/ProviderCatalog.swift` 里加一行，就完成了接入。
//
//  ## 步骤
//
//  1. 在上层目录建一个以稳定 ID 命名的文件夹（小写短横线，发布后不可改），
//     例如 `Providers/Extensions/my-relay/`，把本文件复制进去并改名。
//  2. 把下面所有 `template`/`Template` 占位符替换成你的 ID 与显示名，
//     并把 `<...>` 参数换成真实值。稳定 ID 会写进用户的 subscriptions.json，
//     改名会丢失订阅关联。
//  3. 在 `ProviderCatalog.providers` 里加一行 `TemplateProviderDefinition.myRelay,`。
//     顺序决定 TM-03「选择供应商」页面的卡片顺序。
//  4. 需要自定义图标时把 PNG 放进本文件夹（同步组会自动收录），
//     并在 `iconResourceName` 填不带扩展名的文件名；否则留 nil 用 SF Symbol。
//  5. 构建即可，不需要修改 `project.pbxproj`、注册表、编辑页或任何共享代码。
//
//  ## 参数从哪来
//
//  - 站点域名、登录页、localStorage 键名：浏览器 DevTools 里看 `localStorage`，
//    以及登录后那条取用户信息/余额的请求。
//  - 余额接口路径与字段：看该请求的响应体。
//  - 续期接口：看前端多久发一次 `refresh`，确认请求体与响应字段。
//    若站点不提供续期（token 过期只能重新登录），删掉 `BrowserRelayRefresher`
//    这段，并把 `refresh:` 换成抛 `UsageProviderError.authenticationRequired`。
//
//  ## 可选：换成自定义卡片
//
//  默认沿用余额卡。需要额度进度条时把 `cardRenderer` 换成
//  `QuotaListCardRenderer()`（或带 `anchorHint:` 指定顶部摘要优先匹配的额度名）。
//  布局明显不同的才新建自定义 `ProviderCardRenderer`，放进本文件夹。

// MARK: - 稳定 ID（发布后不可改）

extension ProviderID {
    static let template = ProviderID(rawValue: "template-relay")
}

extension AuthMethodID {
    static let templateBrowserSession = AuthMethodID(rawValue: "template-relay-browser-session")
}

// MARK: - 登录站点

extension BrowserTokenSite {
    /// 站点差异：错误文案短名、登录窗口标题、localStorage 键名、域名与登录页。
    static let template = BrowserTokenSite(
        displayName: "<短名，用于错误文案>",
        loginWindowTitle: "登录 <显示名> 账号",
        accessTokenKey: "auth_token",
        sessionDomains: ["example.invalid"],  // 换成真实域名，不含 https
        loginPageURL: URL(string: "https://example.invalid/login")!  // 换成真实登录页
    )
}


/// 续期入口：`POST {apiBase}/auth/refresh`。接口不同构时删掉这段。
extension BrowserRelayRefresher {
    static let template = BrowserRelayRefresher(
        tokenSite: .template,
        apiBase: URL(string: "https://example.invalid/api/v1")!  // 换成真实 API 前缀
    )
}

// MARK: - 定义

extension RelayBalanceProviderDefinition {
    static let template = RelayBalanceProviderDefinition(
        refresher: .template,
        id: .template,
        displayName: "<显示名>",
        // PNG 放在本文件夹即可，同步组会自动收录；不用图标时留 nil。
        iconResourceName: nil,
        fallbackSystemImage: "bolt.fill",
        tintRGB: 0x2DD4BF,
        homepageURL: URL(string: "https://example.invalid")!,  // 换成真实官网
        authMethod: AuthMethodDefinition(
            id: .templateBrowserSession,
            flowID: .browserSession,
            title: "网页登录态",
            systemImage: "globe",
            tintRGB: 0x2DD4BF,
            detail: "登录 <显示名> 账号（内置）",
            loginRecipe: BrowserTokenSite.template.loginRecipe
        )
    )
}

// MARK: - 接口不同构时：自定义用量提供者
//
// 余额不在 `{apiBase}/auth/me` 的 `data.balance` 时，别用上面的通用定义，
// 改成实现自己的 ProviderDefinition / UsageProvider（参照 Common/RelayBalanceProvider.swift）。
//
// 关键约定：
// - 凭证读写一律走 `CredentialStore`，绝不写入订阅元数据。
// - 浏览器登录态用 `BrowserSessionFlow` 处理「先用现有凭证 → 401/403 时刷新一次再重试」，
//   只有登录态本身失效才抛 `.authenticationRequired`；网络与服务端错误抛 `.requestFailed`。
// - 共享 HTTP 层不认识任何供应商：401/403 的语义由调用方声明的 `HTTPStatusPolicy` 决定，
//   浏览器会话型必须传 `.raw`，否则刷新重试永远不会触发。
// - 解析失败抛 `UsageProviderError.invalidResponse`，不要静默返回空快照。
