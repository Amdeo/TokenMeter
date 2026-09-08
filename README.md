# TokenMeter

> macOS 菜单栏 AI 用量监控 · 在菜单栏随时查看各家 AI 平台的额度与余额
> Track your AI coding-plan quota and account balance right from the macOS menu bar.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![Xcode](https://img.shields.io/badge/Xcode-16.0+-blue)
![License](https://img.shields.io/badge/License-GPL--3.0-blue)

---

## 简介 / Introduction

**TokenMeter** 是一款 macOS 菜单栏应用（SwiftUI，无第三方依赖），帮你集中监控
DeepSeek、Kimi、智谱 AI、OpenCode Go、MiniMax 等平台的 Coding 订阅额度与账户余额，
额度将尽、认证失效或服务异常时通过系统通知提醒，无需打开各家控制台。

**TokenMeter** is a macOS menu-bar app (SwiftUI, zero third-party dependencies) that
monitors coding-plan quotas and account balances across DeepSeek, Kimi, Zhipu AI,
OpenCode Go and MiniMax in one place. Get notified when a quota is running low,
authentication expires, or a service errors out — without opening each provider's console.

---

## 功能特性 / Features

| 功能 Feature | 说明 Description |
| --- | --- |
| 菜单栏实时概览 Menu-bar overview | 所有订阅的额度 / 余额进度一目了然，支持拖拽排序 |
| 多订阅管理 Multiple subscriptions | 添加、编辑、启停、删除、自定义命名 |
| 额度窗口 Quota windows | 支持 5 小时、每周、总用量与余额等多种额度形态 |
| 自定义额度颜色 Custom quota colors | 每种额度可单独配色，明暗主题自动适配 |
| 智能提醒 Notifications | 余额低于阈值、认证失效、服务错误三档提醒 |
| 后台自动刷新 Auto refresh | 60 秒 – 30 分钟可选，默认 2 分钟 |
| 开机启动 Launch at login | 一键注册系统登录项 |
| 外观模式 Appearance | 跟随系统 / 浅色 / 深色 |
| 演示与预览 Demo & preview | Debug 构建内置状态预览，方便调 UI |
| 隐私优先 Privacy-first | 凭据仅存本地私有文件，无遥测、无上报 |

---

## 支持的平台 / Supported Providers

| 平台 Provider | 额度类型 Quota | 认证方式 Auth |
| --- | --- | --- |
| **DeepSeek** | 账户余额 Balance | API Key |
| **Kimi** | Coding 订阅额度（5 小时 / 每周）、余额 | API Key / Kimi Code OAuth / 网页登录态 |
| **智谱 AI Zhipu** | GLM Coding Plan 额度窗口（5 小时 / 每周） | API Key |
| **OpenCode Go** | 用量窗口 Usage windows | API Key |
| **MiniMax** | MiniMax Coding Plan 套餐额度 | API Key |
| **CCBus（AI 巴士）** | 账户余额 Balance | 网页登录态 |
| **APIKEY.FUN** | 账户余额 Balance | 网页登录态 |
| **NowCoding** | 账户余额 + 订阅额度 Balance & quotas | 网页登录态 |

> 需要接入新的供应商？请阅读
> [Adding a provider / 添加供应商](docs/provider-development.md)
> 与 `.pi/skills/add-provider/SKILL.md` 中的扩展契约；
> API 中转站（new-api/one-api 系）可参考 `.pi/skills/add-relay-provider/SKILL.md`
> 通过问答生成对应厂商。
> New provider? Read the [provider development guide](docs/provider-development.md)
> and the `add-provider` skill; relay/gateway sites (new-api/one-api family) can be
> scaffolded via the `add-relay-provider` skill.
>
> Kimi 网页登录态支持在内嵌登录页完成授权（实验性），令牌不会显示在界面中。
> 会话到期后由应用自动续期；README 不再宣称可从 Chrome 会话导入
> （`ChromeSessionImporter` 仅承担 token 续期，登录本身在内嵌页完成）。
> Kimi's web-session auth can be completed in an embedded login page
> (experimental); tokens never appear in the UI. Sessions are renewed
> automatically; Chrome session import is no longer claimed.

---

## 安装 / Installation

### 方式一：Xcode 构建

```bash
git clone <your-repo-url>
cd TokenMeter
open TokenMeter.xcodeproj
```

选择 `TokenMeter` scheme，以 Debug 或 Release 运行（当前仓库未内置签名配置，
如需分发请自行配置 Team 与签名）。

### 方式二：命令行构建

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

> 正式安装包与自动更新暂未提供，欢迎贡献。

---

## 使用 / Usage

1. 点击菜单栏的 TokenMeter 图标打开概览面板。
2. 点击「添加订阅」，选择平台。
3. 按平台选择认证方式：
   - **API Key**：在供应商控制台创建密钥后粘贴（如
     [DeepSeek](https://platform.deepseek.com/api_keys)、
     [Kimi](https://platform.moonshot.cn/console/api-keys)、
     [智谱](https://www.bigmodel.cn/usercenter/proj-mgmt/apikeys)、
     [OpenCode Go](https://opencode.ai/zen)、
     [MiniMax](https://platform.minimaxi.com/user-center/basic-information/interface-key)）。
   - **Kimi Code OAuth**：实验性设备授权流程。
   - **Kimi 网页登录态**：从 Chrome 会话导入或内嵌登录。
4. 回到概览查看实时进度；在设置中配置刷新频率、通知阈值与开机启动。

---

## 设置 / Settings

- **后台自动刷新**：60s / 2min / 5min / 10min / 30min 可选，可关闭。
- **通知提醒**：余额低于阈值（CNY / USD 可分别设置）、认证失效、服务连续错误。
- **开机启动**：通过系统登录项实现，部分系统需在「系统设置 → 通用 → 登录项」中批准。
- **外观**：跟随系统 / 浅色 / 深色。

---

## 隐私与数据 / Privacy & Data

- 所有订阅数据与凭据仅保存在本机
  `~/Library/Application Support/TokenMeter/credentials.json`
  （私有权限文件），不经过任何第三方服务器。
- 应用只访问你配置的供应商官方 API；无遥测、无崩溃上报、无广告。
- 调试期导出的 Kimi 会话文件（`kimi-export-session*.md`）已被 `.gitignore`
  排除，切勿提交；这类文件含会话令牌，本地也应删除并轮换对应凭证。

---

## 开发 / Development

### 构建与测试

```bash
# 构建
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# 测试（Swift Testing）
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

### 目录结构 / Project structure

```text
TokenMeter/
├── TokenMeterApp.swift        # 应用入口
├── Models/                    # 领域模型：订阅、额度、快照
├── Providers/                 # 供应商协议、Demo 数据、实时 API 客户端
├── Services/                  # 凭据存储、Kimi OAuth、Chrome 会话导入、通知
├── Store/                     # UsageStore：共享状态与刷新编排
├── Views/                     # SwiftUI 菜单栏面板与组件
├── Resources/PlatformIcons/   # 供应商图标
└── Tests/                     # Swift Testing 测试
```

技术栈：Swift 6 · SwiftUI · AppKit · ServiceManagement · UserNotifications，
零第三方依赖。

---

## 贡献 / Contributing

欢迎提交 Issue 与 Pull Request。请保持改动聚焦、附上验证命令，涉及 UI 的改动附截图。

Issues and pull requests are welcome. Keep changes focused, include verification
commands, and attach screenshots for UI changes.

---

## 许可证 / License

[GPL-3.0](./LICENSE)
