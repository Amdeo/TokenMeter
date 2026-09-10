# Ponytail 债务账本

本仓库中被 `ponytail:` 注释标记的刻意简化，集中登记，避免「以后再说」变成永远不做。

> 生成自 `/ponytail-debt` 扫描。重新生成：`grep -rnE '(#|//|///) ?ponytail:' .`
> 每行格式：`<file>:<line>, <简化了什么>. ceiling: <上限>. upgrade: <何时回来做>.`

| 位置 | 简化内容 | ceiling | upgrade 触发条件 |
| --- | --- | --- | --- |
| [`TokenMeter/Views/SubscriptionEditorSheet.swift:615`](TokenMeter/Views/SubscriptionEditorSheet.swift) | 浏览器授权 + 手动粘贴授权码，不监听本地回调端口 | 授权码必须手动复制一次，无法自动回填 | 粘贴体验被反馈麻烦时 → 加 `127.0.0.1:54545` 监听自动回填 |
| [`TokenMeter/Providers/BuiltIn/ClaudeProvider.swift:116`](TokenMeter/Providers/BuiltIn/ClaudeProvider.swift) | 429 直接报限流错误，不重试不刷新 | 偶发限流时本次刷新失败，需等下次刷新 | 真实账号频繁撞 429 时 → 加指数退避或降低刷新频率 |
| [`TokenMeter/Providers/BuiltIn/ClaudeProvider.swift:164`](TokenMeter/Providers/BuiltIn/ClaudeProvider.swift) | `limits[]` 的 `weekly_scoped` 仅展示，不参与门控 | 模型级周额度耗尽不会阻止使用，只是显示 | 其他供应商引入阻塞语义时 → 同步 Claude |

## 已排除（曾误记为债务）

- **`anthropic-identity` bootstrap 回退**：`ClaudeOAuthService.credential(from:)` 中 `account.uuid` 只用于展示，额度请求只需要 access token，缺失按可选处理，因此该回退对 TokenMeter 无实际用途，不构成债务。

## 审计后决定不做（复杂度确实存在，但收尾成本 ≥ 收益）

以下来自 `/ponytail-audit` 的全仓扫描。它们**不是代码里的 `ponytail:` 标记**，仅登记结论，避免以后重复评估。

- **合并三个登录态错误枚举**（`KimiBrowserCredentialError` / `APIKeyFunBrowserCredentialError` / `CCBusBrowserCredentialError`，每个约 25 行、逐 case 重复）：合并需要给枚举加供应商维度，波及 34 个 throw 点、3 个 `isInvalid` 闭包和测试里的 `catch` 模式；且 `Views/SubscriptionEditorSheet.swift:315` 会把 `localizedDescription` 直接展示给用户，合并必然改动可见文案。收益约 -50 行。
  - 重新评估的触发条件：当出现第 4 个同构的浏览器会话供应商时（复制成本开始压过迁移成本）。
- **合并 APIKeyFun / CCBus 两个提取器**（各 79 行、约 53 行同构）：共享核心只能抽出 `credential(from:)` 的约 25 行，且需要传入 error-factory 闭包；错误枚举本就该各自独立。收益约 -20 行。
  - 重新评估的触发条件：同上的第 4 个同构供应商，或 localStorage key 约定发生变化导致两份实现不同步时。
- **合并 APIKeyFun / CCBus 的 Provider 定义骨架**（各 102 行、约 64 行同构）：文件分离本身就是本项目「一个中转站一个文件」的扩展机制（见 `add-relay-provider` skill），只应合骨架、不应合文件，收益低于前两条。

---

3 markers, 0 with no trigger.
