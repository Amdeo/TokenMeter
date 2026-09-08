# TokenMeter 优化报告复核

> 复核日期：2026-09-08  
> 对象：`OPTIMIZATION.md` 及当前 `main` 分支源码  
> 范围：Models / Providers / Services / Store / Views / Tests

## 结论

原报告的方向基本正确，但不能直接按原顺序实施。刷新串行化和首刷丢弃是真问题；不过直接改成 `withTaskGroup` 会先暴露凭证文件并发读改写、删除期间回写等更严重的问题。当前代码还存在 Kimi 回退额度不可见、错误被误报为认证失败、元数据写盘失败静默丢失等功能风险。

## 发现

### P1：删除或编辑期间的刷新任务仍会回写

`UsageStore.remove` 会删除快照和凭证，但 `fetch` 在 `await` 返回后无条件写入快照（`TokenMeter/Store/UsageStore.swift:61`、`:127`）。Kimi、CCBus 和 APIKEY.FUN 的刷新路径还可能在等待网络期间重新保存凭证（例如 `TokenMeter/Providers/BuiltIn/KimiProvider.swift:398`）。

结果可能是：已删除订阅留下孤立快照，甚至凭证被重新写回；编辑认证方式时也可能用旧刷新结果覆盖新凭证。应先做每订阅任务取消或 generation 校验，再增加并发。

### P1：Kimi API Key 回退余额不会显示

Kimi Coding 接口遇到 401/403/404 时回退到余额快照（`TokenMeter/Providers/BuiltIn/KimiProvider.swift:80`）。但 `KimiCardRenderer` 只渲染 5 小时和每周额度（`TokenMeter/Views/ProviderCards/KimiCardRenderer.swift:6`），不渲染 `.balance`。

因此回退成功后卡片仍显示两行“接口未返回”，用户看不到有效余额。

### P1：网页态 5 小时额度可能被错误显示为 0%

`fetchBrowserUsage` 把 coding 请求的所有错误都吞掉（`TokenMeter/Providers/BuiltIn/KimiProvider.swift:153`）；随后启用但缺少 `ratio` 的窗口被解析为 `0%`（`:251`）。网络错误、401 或 500 会与真实零使用混淆。

### P1：订阅元数据写盘失败被静默忽略

`saveSubscriptions` 的 `catch` 为空（`TokenMeter/Store/UsageStore.swift:194`）。添加、删除、重命名或排序可能只改了内存，重启后丢失；删除失败时还可能重新出现订阅。

### P2：应用启动不会立即刷新

`UsageStore.start` 先 sleep，再执行第一次 `refreshAll`（`TokenMeter/Store/UsageStore.swift:104`）。默认间隔是 120 秒（`TokenMeter/Services/SettingsStore.swift:148`），最长可达 30 分钟。只有打开面板且启用“打开时刷新”时才会提前触发。

### P2：认证错误分类不完整，刷新错误语义也被压扁

`APIClient.get` 只对 DeepSeek 的 401/403 做认证分类，其他 Provider 走普通 `httpStatus`（`TokenMeter/Providers/Support/APIClient.swift:58`）。MiniMax、Zhipu、OpenCode Go 和 Kimi 余额回退的无效 Key 不会进入认证失效状态。

另一方面，刷新后的第二次请求若遇到网络错误或 500，也会被 CCBus、APIKEY.FUN、Kimi 的重试代码统一转换成“请重新登录”（例如 `TokenMeter/Providers/BuiltIn/KimiProvider.swift:123`）。

### P2：通知 ledger key 对多个 Kimi 余额窗口发生冲突

Kimi 回退快照最多包含三个同为 CNY 的余额额度（`TokenMeter/Providers/BuiltIn/KimiProvider.swift:176`），但通知 key 只包含订阅 ID 和币种（`TokenMeter/Services/NotificationCoordinator.swift:71`）。不同余额会互相覆盖状态，导致低余额提醒重复或漏发。

### P2：OAuth 授权期限字段不应删除

`authorize` 把截止时间固定为 15 分钟（`TokenMeter/Services/KimiOAuthService.swift:41`），而服务端 `expires_in` 产生的 `KimiDeviceAuthorization.expiresAt`（`:202`）没有参与轮询。服务端期限与 15 分钟不一致时，会过早超时或继续轮询已失效设备码。

### P2：NowCoding 的会话和缺失数据边界不严谨

内嵌登录从共享 Cookie Store 里只按名称取第一个 `session`，没有过滤域名（`TokenMeter/Services/EmbeddedNowCodingLoginController.swift:79`）。同时 `me.data` 缺失时被当成 0 余额（`TokenMeter/Providers/BuiltIn/NowCodingProvider.swift:123`），会把未知数据显示成有效零值。

### P2：类型化凭证保存方法没有完全保持互斥

`save(apiKey:)` 和 `save(oauthCredential:)` 没有清除 `cookieCredential`（`TokenMeter/Services/CredentialStore.swift:129`、`:141`）。这与原报告“各自实现同一套互斥清空”的描述不符，也会留下陈旧凭证。

## 对原报告建议的判断

- **成立但需补前置条件**：刷新串行化、首刷丢弃、重复的登录/刷新/中继 Provider 代码、硬编码浏览器认证列表、Kimi coding 请求吞错。
- **不宜直接执行**：把刷新改成无界任务组；必须先处理 `CredentialStore` 的串行写入、任务取消和结果有效性。
- **报告事实不准确**：`get` 并非已经有通用 401/403/429 分类；三个错误枚举也不完全相同，Kimi 还多了 `refreshFailed`。
- **不属于无风险删除**：`makeDemoSnapshot`、`credential(for:flowID:)`、`isDemo` 虽然当前生产调用少，但仍是文档、测试或扩展契约的一部分。
- **不建议改动**：刷新图标的 `.repeatForever` 是不确定进度的合理线性动画，当前没有性能证据支持改成有限动画。
- **建议延后**：控制器、刷新器和 CCBus/APIKEY.FUN Provider 的泛型化主要是维护性重构，不是已证明的运行时优化；NowCoding 的 cookie 流程也不是完全同构。

## 文档与安全问题

README 仍声称支持 Chrome 会话导入，但当前 `ChromeSessionImporter` 只负责刷新；README 的供应商表也漏了 APIKEY.FUN 和 NowCoding。根目录还存在一个被 `.gitignore` 排除、权限为 `0644` 的会话导出文件；忽略规则不等于本地保护。若文件含 session/token，应删除并轮换凭证。本次复核未读取或删除该文件。

## 验证

- `xcodebuild ... test CODE_SIGNING_ALLOWED=NO`：137 个测试通过，0 失败。
- `xcodebuild ... analyze`：通过。
- `SWIFT_STRICT_CONCURRENCY=complete` Debug 构建：通过。
- 现有测试没有覆盖真实 HTTP、刷新调度、删除期间刷新、凭证并发写入和内嵌登录生命周期；因此不能据此排除上述风险。

## 建议顺序

1. 先修任务生命周期/删除竞态与元数据写盘错误。
2. 修复 Kimi 回退渲染、网页态错误与 Provider 认证分类，并补网络 stub 测试。
3. 再设计有界并发和凭证存储串行化。
4. 最后处理重复代码和无调用清理。

本文件是对 `OPTIMIZATION.md` 的独立复核，不修改原报告或源码。
