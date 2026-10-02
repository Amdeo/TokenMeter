# 第三方资源出处

## `Marks/*.svg`

悬浮条上的供应商标记，来自 [Lobe Icons](https://github.com/lobehub/lobe-icons)，
经 [Pulse](https://github.com/qunqin24/Pulse) 整理后取用。

- Lobe Icons：MIT License
- Pulse：Apache License 2.0

各文件对应的上游产品商标归其各自所有者，此处仅作标识之用。

| 文件 | 供应商 | 对应 TokenMeter provider |
| --- | --- | --- |
| `claude.svg` | Claude | `claude` |
| `openai.svg` | OpenAI | `codex` |
| `deepseek.svg` | DeepSeek | `deepseek` |
| `kimi.svg` | Kimi | `kimi` |
| `minimax.svg` | MiniMax | `minimax` |
| `opencode.svg` | OpenCode | `opencode-go` |
| `zai.svg` | Z.ai | `zhipu` |

## `Providers/Extensions/*/icon-*.png`

Codex 与 Claude 的面板图标复用上方现有的 `Marks/openai.svg` 与 `Marks/claude.svg`
路径（来源仍为 Lobe Icons，经 Pulse 整理，许可证见上文），再栅格化为 PNG。
两张 PNG 都是 640×640 方形 tile：原始单色 mark 等比缩放到约 72% 画布并居中，
Codex 使用纯白背景，Claude 使用暖浅色背景 `#FAF9F5`，其 mark 使用 Claude 橙
`#D97757`。不添加圆角，圆角由 `PlatformLogo` 统一裁剪。上游品牌标记归各自所有者所有。

| 文件 | 上游资产 | 对应 TokenMeter provider |
| --- | --- | --- |
| `Providers/Extensions/codex/icon-codex.png` | 现有 `Marks/openai.svg` 的 OpenAI knot 路径栅格化 | `codex` |
| `Providers/Extensions/claude/icon-claude.png` | 现有 `Marks/claude.svg` 的 Claude 放射星路径栅格化并着色 `#D97757` | `claude` |

## `Marks/apikeyfun.png`

唯一一张**位图**标记：APIKEY.FUN 没有公开的矢量 logo（官网只有 `/logo.png`），
Lobe Icons 与 Simple Icons 也都没有收录。这张是从该供应商自己的应用图标
（`Providers/Extensions/apikey-fun/icon-apikeyfun.png`）剥出的**单色剪影**：
去白底 → 归一化 → 取 alpha，黑墨透明底，256×256。

商标归 APIKEY.FUN 所有，此处仅作标识之用。

其余三个中转站（CCBus / NowCoding / Siyu API）的图标是带底色的彩色插画，
剥成 18pt 的单色剪影只会糊成一团，所以它们继续用 `fallbackSystemImage` 的 SF Symbol。
