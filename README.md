# TokenMeter

**简体中文** | [English](README.en.md)

> 在 macOS 菜单栏集中查看各家 AI Coding 平台的额度与余额，额度将尽时自动提醒。

![Screenshot](docs/images/menubar-screenshot.png)

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-GPL--3.0-blue)

## 为什么需要它

如果你同时使用多个 AI Coding 订阅（DeepSeek、Kimi、智谱 GLM、Claude、Codex……），
每个平台的额度入口和刷新周期都不一样，很难一眼知道「哪个号快用完了」。
TokenMeter 把它们全部收进一个菜单栏面板：实时进度、剩余余额、到期提醒，
无需打开任何控制台。

## 功能

- **菜单栏实时概览** — 所有订阅的额度 / 余额进度一目了然，支持拖拽排序
- **多订阅管理** — 同一平台可添加多个账号，支持编辑、启停、删除、自定义命名
- **多种额度形态** — 5 小时窗口、每周窗口、每月窗口、总用量、账户余额
- **自定义额度颜色** — 每种额度可单独配色，明暗主题自动适配
- **智能提醒** — 余额低于阈值、认证失效、服务连续错误三档系统通知
- **后台自动刷新** — 60 秒至 30 分钟可选，默认 2 分钟
- **开机启动** — 一键注册系统登录项
- **外观模式** — 跟随系统 / 浅色 / 深色
- **隐私优先** — 凭据仅存本地，无遥测、无上报、零第三方依赖

## 支持的平台

| 平台 | 额度类型 | 认证方式 |
| --- | --- | --- |
| **DeepSeek** | 账户余额 | API Key |
| **Kimi** | Coding 订阅额度（5 小时 / 每周）、余额 | API Key / Kimi Code OAuth / 网页登录态 |
| **智谱 AI** | GLM Coding Plan 额度窗口（5 小时 / 每周） | API Key |
| **OpenCode Go** | 用量窗口（5 小时 / 每周 / 每月） | API Key |
| **MiniMax** | MiniMax Coding Plan 套餐额度 | API Key |
| **Claude** | Pro/Max 订阅额度（5 小时 / 每周） | Claude OAuth |
| **OpenAI Codex** | Codex 订阅额度（5 小时 / 每周） | Codex 设备 OAuth（实验性） |
| **CCBus（AI 巴士）** | 账户余额 | 网页登录态 |
| **APIKEY.FUN** | 账户余额 | 网页登录态 |
| **NowCoding** | 账户余额 + 订阅额度 | 网页登录态 |

> 想接入新的供应商？请阅读 [供应商开发指南](docs/provider-development.md)。
> API 中转站（new-api / one-api 系）有对应的脚手架支持，详见指南中的说明。

## 安装

目前需要自行构建（未提供正式安装包，欢迎贡献分发配置）：

```bash
git clone https://github.com/<your-org>/TokenMeter.git
cd TokenMeter
open TokenMeter.xcodeproj
```

在 Xcode 中选择 `TokenMeter` scheme 运行即可。如需命令行构建：

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

> 仓库未内置代码签名配置；如需分发，请自行在 Xcode 中配置 Team 与签名。

## 快速上手

1. 点击菜单栏的 TokenMeter 图标，打开概览面板。
2. 点击「添加订阅」，选择平台。
3. 按平台完成认证：
   - **API Key**：在供应商控制台创建密钥后粘贴
     （[DeepSeek](https://platform.deepseek.com/api_keys) ·
     [Kimi](https://platform.moonshot.cn/console/api-keys) ·
     [智谱](https://www.bigmodel.cn/usercenter/proj-mgmt/apikeys) ·
     [OpenCode Go](https://opencode.ai/zen) ·
     [MiniMax](https://platform.minimaxi.com/user-center/basic-information/interface-key)）
   - **OAuth**（Claude / Codex / Kimi Code）：按提示完成浏览器授权
   - **网页登录态**（CCBus / APIKEY.FUN / NowCoding / Kimi）：在内嵌登录页完成授权，令牌不会显示在界面中
4. 回到概览查看实时进度；在设置中配置刷新频率、通知阈值与开机启动。

## 设置

- **后台自动刷新**：60s / 2min / 5min / 10min / 30min，可关闭
- **通知提醒**：余额低于阈值（CNY / USD 分别设置）、认证失效、服务连续错误
- **开机启动**：通过系统登录项实现，部分系统需在「系统设置 → 通用 → 登录项」中批准
- **外观**：跟随系统 / 浅色 / 深色

## 隐私与数据

- 所有订阅数据与凭据仅保存在本机
  `~/Library/Application Support/TokenMeter/credentials.json`（私有权限文件），
  不经过任何第三方服务器。
- 应用只访问你配置的供应商官方 API；无遥测、无崩溃上报、无广告。

## 开发

技术栈：Swift 6 · SwiftUI · AppKit · ServiceManagement · UserNotifications，零第三方依赖。

```bash
# 构建
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# 测试（Swift Testing）
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

目录结构：

```text
TokenMeter/
├── TokenMeterApp.swift        # 应用入口
├── Models/                    # 领域模型：订阅、额度、快照
├── Providers/                 # 供应商协议、内置供应商实现
├── Services/                  # 凭据存储、OAuth、通知
├── Store/                     # UsageStore：共享状态与刷新编排
├── Views/                     # SwiftUI 菜单栏面板与组件
├── Resources/PlatformIcons/   # 供应商图标
└── Tests/                     # Swift Testing 测试
```

## 贡献

欢迎提交 Issue 与 Pull Request。请保持改动聚焦、附上验证命令，涉及 UI 的改动附截图。
新增供应商请参考 [docs/provider-development.md](docs/provider-development.md)。

## 许可证

[GPL-3.0](./LICENSE)
