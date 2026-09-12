# TokenMeter

**简体中文** | [English](README.en.md)

> 在 macOS 菜单栏集中查看已配置 AI Coding 账户的用量与余额。

![Screenshot](docs/images/menubar-screenshot.png)

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-GPL--3.0-blue)

## 当前能力

- 菜单栏概览：查看已配置账户的额度窗口、用量或余额；可添加、编辑、删除及拖拽排序订阅。
- 后台刷新：60 秒至 30 分钟可选，默认 2 分钟；可关闭。
- 系统通知：仅针对低余额、认证失效和连续服务错误。它**不会**发送额度耗尽、套餐到期或订阅续期提醒。
- 设置：通知阈值、开机启动和跟随系统／浅色／深色外观。

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

不同供应商的接口和账号权限会影响可显示的数据；TokenMeter 不承诺账户一定具备所有项目。新增供应商请阅读[供应商开发指南](docs/provider-development.md)。

## 安装

### 已发布版本

[v0.1.0](https://github.com/Amdeo/TokenMeter/releases/tag/v0.1.0) 提供 `TokenMeter-0.1.0-macOS.zip`。该发布包是未签名构建；请从 GitHub Release 下载、解压后按 macOS 的安全提示操作。发布版本与 `main` 分支不同：`main` 包含发布后的开发改动，适合需要从源码构建的用户。

### 从源码构建

需要 macOS 14 或更高版本，以及 Xcode 26 或更高版本（项目使用 macOS 26 SDK 符号）。

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

未签名源码构建的运行或分发可能需要你在 Xcode 中配置自己的 Team 和签名。

## 快速上手

1. 点击菜单栏的 TokenMeter 图标，打开概览。
2. 选择「添加订阅」，再选择供应商。
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

## 许可证

[GPL-3.0](./LICENSE)
