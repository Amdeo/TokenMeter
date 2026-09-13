# TokenMeter

**简体中文** | [English](README.en.md)

> **macOS 菜单栏上的 AI 用量与余额监控。** 把官方订阅的额度窗口（Kimi、Claude Code、Codex、智谱 GLM、DeepSeek、MiniMax、OpenCode Go）和第三方 AI 中转站余额（CCBus、APIKEY.FUN、NowCoding、Siyu）放进同一块菜单栏面板：常驻后台自动刷新，低余额与认证失效时通知你。

![Screenshot](docs/images/menubar-screenshot.png)

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-GPL--3.0-blue)
[![CI](https://github.com/Amdeo/TokenMeter/actions/workflows/ci.yml/badge.svg)](https://github.com/Amdeo/TokenMeter/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Amdeo/TokenMeter)](https://github.com/Amdeo/TokenMeter/releases)

**中文关键词**：macOS 菜单栏 App · AI 用量监控 · 额度窗口（5 小时 / 每周 / 每月） · 余额查询 · **AI 中转站余额** · Kimi 余额 · Claude Code 用量 · Codex 用量 · 智谱 GLM · DeepSeek · MiniMax · OpenCode Go · CCBus / APIKEY.FUN / NowCoding / Siyu · API Key / OAuth / 网页登录态
**English keywords**：macOS menu bar AI usage tracker · LLM quota and balance monitor · Claude Code / Codex / Kimi / DeepSeek usage · API relay balance · SwiftUI menu bar app

## 为什么用 TokenMeter

- **官方订阅与中转站放在一起**：11 个供应商，既有官方订阅的额度窗口，也有第三方中转站的账户余额，不用开两个工具、两套登录。
- **三种认证都支持**：API Key、OAuth（设备授权 / 授权码），以及**网页登录态**——在内置浏览器里登录一次即可，不需要手动抠 token，也不用装插件。
- **额度窗口与余额混排**：5 小时 / 每周 / 每月窗口、套餐额度与账户余额按供应商自适应成卡片，支持多账户与拖拽排序。
- **原生实现**：Swift 6 + SwiftUI/AppKit，不含第三方依赖；菜单栏常驻，后台刷新 60 秒～30 分钟可调。
- **克制的通知**：只报低余额、认证失效与连续服务错误，不推送额度耗尽、套餐到期这类噪音。
- **透明且本地**：无遥测、无广告、无崩溃上报；凭据只保存在本机私有文件（目录 `0700`、文件 `0600`），并提供加密的凭据迁移包。
- **可扩展**：新增一个供应商 = `Providers/Extensions/<id>/` 下一个目录 + `ProviderCatalog` 一行，参见[供应商开发指南](docs/provider-development.md)。

## 与同类工具的差异

同类项目各有侧重（各家能力以各自仓库说明为准），TokenMeter 的取向是「一块面板同时管官方额度与中转余额」：

| 项目 | 侧重 | TokenMeter 的做法 |
| --- | --- | --- |
| [oh-myusage](https://github.com/Four-JJJJ/oh-myusage) | 菜单栏汇总官方订阅额度、中转余额与本地 Codex 账号状态 | 同样覆盖两类数据源，另提供内置浏览器网页登录态与加密凭据迁移 |
| [token-remain](https://github.com/Carstin520/token-remain) | 隐私优先的 AI 编程额度与重置时间跟踪 | 余额与额度窗口一起读，并覆盖 CCBus / APIKEY.FUN / NowCoding / Siyu 等中转站 |
| [Any-Api-Check](https://github.com/xiaopenghuang/Any-Api-Check) | 中转站余额与调用日志查询 | 中转余额与官方订阅额度同屏，常驻菜单栏自动刷新并做低余额通知 |
| [limit-monitor](https://github.com/DjentieY/limit-monitor) | Claude / Codex / Cursor 的速率窗口 | 覆盖 11 家供应商的额度窗口与余额，含 Kimi、智谱、MiniMax、OpenCode Go 与网页登录态 |

## 当前能力

- 菜单栏概览：查看已配置账户的额度窗口、用量或余额；可添加、编辑、删除及拖拽排序订阅。添加订阅、设置与退出在右击菜单栏图标弹出的菜单里。
- 后台刷新：60 秒至 30 分钟可选，默认 2 分钟；可关闭。
- 系统通知：仅针对低余额、认证失效和连续服务错误。它**不会**发送额度耗尽、套餐到期或订阅续期提醒。
- 设置：通知阈值、开机启动、跟随系统／浅色／深色外观，以及浅色外观下的磨砂玻璃背景开关。

界面目前仅提供简体中文；本文档提供中英文版本。应用不提供单个账户的刷新启停开关，也不管理供应商的订阅购买与计费。

## 支持的平台

| 平台 | 可读取的数据 | 认证方式 |
| --- | --- | --- |
| DeepSeek | 账户余额 | API Key |
| Kimi | Coding 用量窗口／余额（依认证方式而定） | API Key、Kimi Code OAuth、网页登录态 |
| 智谱 AI | GLM Coding Plan 用量窗口 | API Key |
| OpenCode Go | 用量窗口 | API Key |
| MiniMax | Coding Plan 额度 | API Key |
| Claude | Pro/Max 用量窗口 | Claude OAuth |
| OpenAI Codex | Codex 用量窗口 | Codex 设备 OAuth（实验性） |
| CCBus | 账户余额 | 网页登录态 |
| APIKEY.FUN | 账户余额 | 网页登录态 |
| NowCoding | 账户余额和订阅额度 | 网页登录态 |
| Siyu API | 账户余额、每日／每周／每月 月卡额度窗口 | 网页登录态 |

不同供应商的接口和账号权限会影响可显示的数据；TokenMeter 不承诺账户一定具备所有项目。新增供应商请阅读[供应商开发指南](docs/provider-development.md)。

## 安装

### 已发布版本

[v0.1.0](https://github.com/Amdeo/TokenMeter/releases/tag/v0.1.0) 提供 `TokenMeter-0.1.0-macOS.zip`。该发布包是未签名构建；请从 GitHub Release 下载、解压后按 macOS 的安全提示操作。发布版本与 `main` 分支不同：`main` 包含发布后的开发改动，适合需要从源码构建的用户。

未签名构建没有 Developer ID 签名和 Apple 公证，首次打开时 macOS 会拦截：

1. 解压后把 `TokenMeter.app` 拖入 `/Applications`。
2. 在 Finder 中按住 Control 点击该应用，选择「打开」，再在弹窗中选择「打开」；或前往「系统设置 → 隐私与安全性」，在安全提示处选择「仍要打开」。
3. 如果系统提示应用「已损坏」，先与 Release 同时发布的校验值文件比对 `shasum -a 256`；校验一致时执行 `xattr -dr com.apple.quarantine /Applications/TokenMeter.app`，然后重新打开。

只从本仓库的 GitHub Release 下载构建产物。签名与公证流程见[贡献指南](CONTRIBUTING.md)。

### 从源码构建

需要 macOS 14 或更高版本，以及 Xcode 26 或更高版本。本仓库当前在以下环境开发与构建：

| 项目 | 版本 |
| --- | --- |
| 开发系统 | macOS 26.5.2（25F84） |
| 最低系统 | macOS 14.0 |
| macOS SDK（API） | 26.5 |
| Xcode | 26.6（17F113） |
| Swift | 工程 6.0，编译器 6.3.3 |

```bash
git clone https://github.com/Amdeo/TokenMeter.git
cd TokenMeter
open TokenMeter.xcodeproj
```

在 Xcode 中选择 `TokenMeter` scheme 后运行。命令行构建：

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

未签名源码构建的运行或分发可能需要你在 Xcode 中配置自己的 Team 和签名。系统通知还要求构建带有 Apple 开发者签名：macOS 拒绝为未签名（仅 linker/ad-hoc 签名）的应用注册通知。应用启动时会主动请求一次通知授权（仅在开启提醒且系统尚未决定时），被拒原因显示在设置面板中。

## 快速上手

1. 点击菜单栏的 TokenMeter 图标，打开概览；右击该图标打开菜单（添加订阅、设置、退出）。
2. 在菜单里选择「添加订阅」，再选择供应商；概览为空时也可直接点面板里的「添加订阅」。
3. 使用该供应商要求的 API Key、OAuth 或网页登录流程完成认证。
4. 回到概览查看可用数据；在设置中调整刷新频率和通知选项。

只在供应商的官方入口创建 API Key。OAuth 与网页会话会在应用所用的授权页面中完成；实验性 OAuth 的限制见[安全说明](SECURITY.md)。

## 数据与隐私

TokenMeter 不包含遥测、崩溃上报或广告代码，但它会直接访问你配置的供应商端点。请在添加账号前了解该供应商的服务和隐私条款。

本机持久化数据包括：

- `~/Library/Application Support/TokenMeter/credentials.json`：API Key、OAuth access/refresh token，或网页登录 token／会话 cookie。这是**明文 JSON**，不是钥匙串；应用写入时将目录设为 `0700`、文件设为 `0600`。同一 macOS 用户及可读取该文件的本地软件仍应被视为能访问这些凭据。
- `~/Library/Application Support/TokenMeter/subscriptions.json`：订阅名称、供应商、认证方式、启停和配色等元数据；它不应包含凭据。
- `UserDefaults`：刷新、通知阈值与开关、外观、开机启动、通知去重记录和面板大小等设置。
- WebKit 默认网站数据存储：通过内嵌网页登录的站点可能保留 cookie、local storage 和其他网站数据，以便下次登录；应用在需要时会按站点清除相关数据。

不要将上述文件、截图、日志或浏览器导出物公开。详细的安全边界和报告方式见 [SECURITY.md](SECURITY.md)。

## 开发与贡献

项目使用 Swift 6、SwiftUI、AppKit、ServiceManagement 和 UserNotifications，不含第三方依赖。离线测试与贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)；新增供应商还必须遵循[供应商开发指南](docs/provider-development.md)。公开问题请使用 GitHub Issues，并且绝不要附带 API Key、token、cookie 或完整凭据文件。

## 打赏

如果 TokenMeter 帮你省了时间，欢迎用微信扫码打赏：

<img src="docs/images/wechat-donate.png" alt="微信赞赏码" width="260">

## 许可证

[GPL-3.0](./LICENSE)
