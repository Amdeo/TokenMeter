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

## `Marks/apikeyfun.png`

唯一一张**位图**标记：APIKEY.FUN 没有公开的矢量 logo（官网只有 `/logo.png`），
Lobe Icons 与 Simple Icons 也都没有收录。这张是从该供应商自己的应用图标
（`Providers/Extensions/apikey-fun/icon-apikeyfun.png`）剥出的**单色剪影**：
去白底 → 归一化 → 取 alpha，黑墨透明底，256×256。

商标归 APIKEY.FUN 所有，此处仅作标识之用。

其余三个中转站（CCBus / NowCoding / Siyu API）的图标是带底色的彩色插画，
剥成 18pt 的单色剪影只会糊成一团，所以它们继续用 `fallbackSystemImage` 的 SF Symbol。
