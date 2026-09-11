# TokenMeter

[简体中文](README.md) | **English**

> Track quota and balance for your AI coding subscriptions right from the macOS menu bar.

![Screenshot](docs/images/menubar-screenshot.png)

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-GPL--3.0-blue)

## Why TokenMeter

If you juggle several AI coding subscriptions (DeepSeek, Kimi, Zhipu GLM, Claude,
Codex...), each provider surfaces its usage in a different console with its own
refresh cycle. TokenMeter pulls them all into one menu-bar panel: live progress
bars, remaining balance, and alerts when a quota runs low — no console-hopping.

## Features

- **Menu-bar overview** — progress for every subscription at a glance, drag to reorder
- **Multiple subscriptions** — add several accounts per provider; edit, toggle, delete, rename
- **Various quota shapes** — 5-hour windows, weekly windows, monthly windows, total usage, account balance
- **Custom quota colors** — per-quota colors, adapting to light/dark mode
- **Smart notifications** — low balance, expired authentication, repeated service errors
- **Background refresh** — 60 s to 30 min, 2 min by default
- **Launch at login** — one-click login item registration
- **Appearance** — follow system / light / dark
- **Privacy-first** — credentials stay on your machine; no telemetry, no third-party dependencies

## Supported Providers

| Provider | Quota | Auth |
| --- | --- | --- |
| **DeepSeek** | Account balance | API Key |
| **Kimi** | Coding plan quota (5-hour / weekly), balance | API Key / Kimi Code OAuth / web session |
| **Zhipu AI** | GLM Coding Plan windows (5-hour / weekly) | API Key |
| **OpenCode Go** | Usage windows (5-hour / weekly / monthly) | API Key |
| **MiniMax** | MiniMax Coding Plan quota | API Key |
| **Claude** | Pro/Max plan quota (5-hour / weekly) | Claude OAuth |
| **OpenAI Codex** | Codex plan quota (5-hour / weekly) | Codex device OAuth (experimental) |
| **CCBus** | Account balance | Web session |
| **APIKEY.FUN** | Account balance | Web session |
| **NowCoding** | Balance + plan quotas | Web session |

> Want to add a provider? See the [provider development guide](docs/provider-development.md).
> Relay/gateway sites (new-api / one-api family) have dedicated scaffolding support —
> see the guide for details.

## Installation

Build from source (no official release package yet — contributions welcome):

```bash
git clone https://github.com/<your-org>/TokenMeter.git
cd TokenMeter
open TokenMeter.xcodeproj
```

Select the `TokenMeter` scheme in Xcode and run. Or build from the command line:

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

> The repo ships no code-signing configuration; configure your Team and signing
> in Xcode if you want to distribute builds.

## Getting Started

1. Click the TokenMeter icon in the menu bar to open the overview panel.
2. Click "Add subscription" and pick a provider.
3. Complete authentication for the provider:
   - **API Key**: create a key in the provider console and paste it
     ([DeepSeek](https://platform.deepseek.com/api_keys) ·
     [Kimi](https://platform.moonshot.cn/console/api-keys) ·
     [Zhipu](https://www.bigmodel.cn/usercenter/proj-mgmt/apikeys) ·
     [OpenCode Go](https://opencode.ai/zen) ·
     [MiniMax](https://platform.minimaxi.com/user-center/basic-information/interface-key))
   - **OAuth** (Claude / Codex / Kimi Code): follow the in-app browser authorization flow
   - **Web session** (CCBus / APIKEY.FUN / NowCoding / Kimi): authorize in the embedded
     login page; tokens are never shown in the UI
4. Back on the overview, watch live progress; configure refresh interval,
   notification thresholds, and launch-at-login in Settings.

## Settings

- **Background refresh**: 60 s / 2 min / 5 min / 10 min / 30 min, can be disabled
- **Notifications**: low balance (separate CNY / USD thresholds), expired auth, repeated service errors
- **Launch at login**: via system login items; some systems require approval in
  "System Settings → General → Login Items"
- **Appearance**: follow system / light / dark

## Privacy & Data

- All subscription data and credentials are stored locally in
  `~/Library/Application Support/TokenMeter/credentials.json` (private-permission
  file). Nothing goes through third-party servers.
- The app only talks to the official APIs of the providers you configure;
  no telemetry, no crash reporting, no ads.

## Development

Stack: Swift 6 · SwiftUI · AppKit · ServiceManagement · UserNotifications,
zero third-party dependencies.

```bash
# Build
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Test (Swift Testing)
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

Project layout:

```text
TokenMeter/
├── TokenMeterApp.swift        # App entry point
├── Models/                    # Domain models: subscriptions, quotas, snapshots
├── Providers/                 # Provider protocol and built-in providers
├── Services/                  # Credential storage, OAuth, notifications
├── Store/                     # UsageStore: shared state and refresh orchestration
├── Views/                     # SwiftUI menu-bar panel and components
├── Resources/PlatformIcons/   # Provider icons
└── Tests/                     # Swift Testing suite
```

## Contributing

Issues and pull requests are welcome. Keep changes focused, include verification
commands, and attach screenshots for UI changes. For new providers, see
[docs/provider-development.md](docs/provider-development.md).

## License

[GPL-3.0](./LICENSE)
