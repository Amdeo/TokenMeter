# TokenMeter 优化报告

> 生成日期:2026-09-08 · 基于当前 `main` 分支源码审查
> 范围:全部 ~10,000 行 Swift(Models / Providers / Services / Store / Views / Tests)

总体评价:代码整体健康(Swift 6 + SwiftUI,零第三方依赖,测试覆盖良好),主要问题是**复制粘贴泛滥**(内嵌登录、凭证提取、中继供应商)和**刷新路径的并发/丢弃问题**。

---

## 一、建议先修(影响真实体验)

### 1. 刷新串行化 + 新订阅首刷被丢弃

**位置**:`TokenMeter/Store/UsageStore.swift:87-102`

- `refreshAll` 对每个订阅 `await` 串行执行;`isRefreshing` 是全局互斥锁,一个慢请求会挂住全部订阅。8 个订阅最坏情况刷新耗时 = 8 × 单次网络延迟。
- `refresh(_:)` 中 `guard !isRefreshing else { return }` 静默跳过:刚添加/编辑的订阅若撞上后台刷新进行中,新卡片会停留在「等待首次刷新…」直到下一个刷新周期。

**修法**:用 `withTaskGroup` 并发刷新全部订阅;`isRefreshing` 改为「最近请求去重」(记录 lastRefreshAt / 活跃 refreshTask 引用)而非全局互斥。两处一同修改。

### 2. 四个内嵌登录控制器约 95% 复制

**位置**:`TokenMeter/Services/EmbeddedKimiLoginController.swift:42-117`、`EmbeddedCCBusLoginController.swift`、`EmbeddedAPIKeyFunLoginController.swift`、`EmbeddedNowCodingLoginController.swift`

- NSPanel 构造、1s 轮询循环、`windowWillClose`、`closePanel`、`extractIfReady` 骨架逐行相同,仅域名 / 首 URL / 提取器不同(`NowCoding` 为 cookie 变体)。
- 4 个文件合计约 340 行样板。

**修法**:收敛为 1 个泛型控制器 + 4 个配置(参数化 domain / loginURL / extractor / credential 类型)。

### 3. 认证服务层复制粘贴

**位置**:
- `expiration(of:)` JWT 解析函数共 5 份:`KimiBrowserCredentialExtractor.swift:6-52`、`CCBusBrowserCredentialExtractor.swift`、`APIKeyFunBrowserCredentialExtractor.swift`、`CCBusSessionRefresher.swift:65-78`、`APIKeyFunSessionRefresher.swift:65-78`
- 3 个错误枚举(`KimiBrowserCredentialError` / `CCBusBrowserCredentialError` / `APIKeyFunBrowserCredentialError`)结构完全相同
- `CCBusSessionRefresher.swift` 与 `APIKeyFunSessionRefresher.swift` 两文件约 95% 相同,仅 URL 基址不同,含重复的 `RefreshResponse` 结构

**修法**:一个参数化 `SessionRefresher`(传入 baseURL)+ 一个参数化 extractor(传入 localStorage key),`expiration(of:)` 收敛为 1 份,错误枚举收敛为 1 个带 displayName 参数。

### 4. CCBus 与 APIKEY.FUN 两个 Provider 文件 90% 重复

**位置**:`TokenMeter/Providers/BuiltIn/CCBusProvider.swift` vs `APIKeyFunProvider.swift`

- 121 行文件仅 21 处不同(名字 / URL / 颜色),其余逐行相同。
- 「过期先刷 → 401 再刷 → 回写」三段式刷新逻辑在仓库中共出现 3 份(CCBus、APIKEY.FUN、`KimiProvider.swift:387-423` 的 `fetchBrowserSessionUsage`)。

---

## 二、低成本清理

| 位置 | 问题 | 修法 |
| --- | --- | --- |
| `UsageStore.swift:133-172` | 错误处理 4 个几乎相同的分支(notConfigured / authenticationRequired / failure / unsupported) | 折叠为约 10 行 |
| `Providers/Support/APIClient.swift:29-115` | `get` / `post` 高度重复;`post` 缺少 `get` 的 401/402/429 状态分类与错误日志 | 合并为一个 `send(method:)` |
| `Services/CredentialStore.swift:117-171` | 泛型 `save(_ StoredCredential:)` 与 4 个类型化 `save(apiKey/oauth/browser/cookie:)` 并存,各自实现同一套互斥清空;`credential(for:flowID:)` 生产代码零调用(仅测试使用) | Provider 统一走泛型入口,删除 4 个专用方法 |
| `Providers/ProviderDefinition.swift:14` | `makeDemoSnapshot` 协议要求被全部 8 个供应商实现,但生产代码无任何调用者 | 从协议删除(及全部实现) |
| `Models/UsageModels.swift:244, 395, 393, 173, 409-410` | `overallStatus` / `limitText` / `usedText`(仅测试用)/ `isDemo` / `tokenMeterTimeText` / `tokenMeterResetText` 均无生产调用者 | 删除 |
| `KimiProvider.swift:375-381` | `date(from:)` 每次调用新建 2 个 `ISO8601DateFormatter`(每条 quota 解析都会调用) | static 单例(注意 formatter 非线程安全,按需上锁或使用本地线程隔离) |
| `MenuBarView.swift:645-655` | 刷新旋转用 `.repeatForever` 无限动画,刷新持续期间主线程每帧渲染 | 改用有限时长动画或周期脉冲 |
| `NotificationCoordinator.swift:138-139` | `persist()` 每次 evaluate 将整个 ledger 全量写 UserDefaults(每个订阅每次刷新 1-3 次) | 仅在状态变更时写入 |
| `KimiOAuthService.swift:3-7` | `KimiDeviceAuthorization.expiresAt` 全代码库无读取者 | 删除 |
| `Views/SettingsPanel.swift:140-230` | `settingsToggle` / `appearanceRow` / `refreshIntervalRow` / `thresholdRow` 重复同一 HStack+divider 行骨架(每份约 20 行) | 收敛为通用 `SettingsRow` |

---

## 三、已知但低风险

- `KimiProvider.swift:145-168`:`fetchBrowserUsage` 无条件吞掉 coding-usage 请求错误(含网络错误)静默降级为空,故障被遮蔽。建议至少区分网络错误与解析错误(仅解析失败可降级)。
- 根目录 `kimi-export-session_*.md`(226KB)未被 git 跟踪,README 已警告勿提交;建议删除本地文件。
- `ChromeSessionImporter.swift`:名为「Chrome 会话导入器」,实际既不做 Chrome 导入、又被内嵌登录复用,真实职责是 Kimi 会话刷新器加一个 quotaURL 常量——命名债。
- `Views/SubscriptionEditorSheet.swift:122, 238-241`:4 段 `authMethodID == .xxx` 硬编码列表重复两处且绕过 `flowID == .browserSession` 判定,新增浏览器会话供应商时易漏改。

---

## 四、建议执行顺序

1. **先修第 1 条(刷新并发 + 首刷丢弃)**:唯一影响日常使用的功能问题,改动集中在一个文件。
2. 复制粘贴收敛(2-4 条)为纯代码债务,功能正常;建议等到有新增供应商需求时一起动手——现在的供应商扩展流程本身就是"复制第 N 份样板"。
3. 第二部分低成本清理可随时顺手做,风险极低。