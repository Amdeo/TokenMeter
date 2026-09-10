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

---

3 markers, 0 with no trigger.
