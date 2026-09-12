# TokenMeter

[简体中文](README.md) | **English**

> View usage and balances for configured AI coding accounts from the macOS menu bar.

![Screenshot](docs/images/menubar-screenshot.png)

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-GPL--3.0-blue)

## Current capabilities

- Menu-bar overview of configured accounts' usage windows, usage, or balances; add, edit, delete, and reorder subscriptions.
- Background refresh from 60 seconds to 30 minutes, with a two-minute default and an off switch.
- System notifications only for low balances, failed authentication, and repeated service errors. It does **not** alert on quota exhaustion, plan expiry, or subscription renewal.
- Settings for notification thresholds, launch at login, and system/light/dark appearance.

The app UI is currently Simplified Chinese only; these docs are available in Chinese and English. There is no per-account refresh toggle. TokenMeter does not manage plan purchases or billing.

## Supported providers

| Provider | Data it can read | Authentication |
| --- | --- | --- |
| DeepSeek | Account balance | API key |
| Kimi | Coding usage windows/balance, depending on auth method | API key, Kimi Code OAuth, web session |
| Zhipu AI | GLM Coding Plan usage windows | API key |
| OpenCode Go | Usage windows | API key |
| MiniMax | Coding Plan quotas | API key |
| Claude | Pro/Max usage windows | Claude OAuth |
| OpenAI Codex | Codex usage windows | Codex device OAuth (experimental) |
| CCBus | Account balance | Web session |
| APIKEY.FUN | Account balance | Web session |
| NowCoding | Account balance and subscription quotas | Web session |

Provider APIs and account permissions determine what can be displayed; TokenMeter does not guarantee that every account exposes every item. To add a provider, read the [provider development guide](docs/provider-development.md).

## Installation

### Published release

[v0.1.0](https://github.com/Amdeo/TokenMeter/releases/tag/v0.1.0) provides `TokenMeter-0.1.0-macOS.zip`. It is an unsigned build: download it from the GitHub Release, unpack it, and follow macOS security prompts. The release and `main` are different: `main` contains development changes made after the release and is intended for users building from source.

The unsigned build has no Developer ID signature and is not notarized, so macOS blocks it on first launch:

1. Unpack the archive and move `TokenMeter.app` into `/Applications`.
2. In Finder, Control-click the app, choose **Open**, then choose **Open** again in the dialog; or open **System Settings → Privacy & Security** and choose **Open Anyway** for the blocked app.
3. If macOS reports the app is damaged, compare `shasum -a 256` against the checksum published with the release first. When it matches, run `xattr -dr com.apple.quarantine /Applications/TokenMeter.app` and open the app again.

Download builds only from this repository's GitHub Release. Signing and notarization are documented in [CONTRIBUTING.md](CONTRIBUTING.md).

### Build from source

Use macOS 14 or later and Xcode 26 or later; the project uses macOS 26 SDK symbols.

```bash
git clone https://github.com/Amdeo/TokenMeter.git
cd TokenMeter
open TokenMeter.xcodeproj
```

Select the `TokenMeter` scheme and run in Xcode. To build from the command line:

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Running or distributing an unsigned source build may require your own Xcode Team and signing configuration. System notifications additionally require a build signed with an Apple developer certificate: macOS refuses to register an unsigned (linker/ad-hoc signed only) app for notifications. The app requests notification authorization once at launch (only when alerts are enabled and the system has not decided yet), and the settings panel reports any refusal reason.

## Get started

1. Click the TokenMeter menu-bar icon to open the overview.
2. Choose **Add subscription**, then choose a provider.
3. Complete that provider's API-key, OAuth, or web-login flow.
4. Return to the overview to see available data; adjust refresh and notification settings as needed.

Create API keys only through a provider's official interface. OAuth and web sessions are completed on the authorization page used by the app; see [SECURITY.md](SECURITY.md) for limits around experimental OAuth.

## Data and privacy

TokenMeter has no telemetry, crash-reporting, or advertising code, but it directly contacts the endpoints of providers that you configure. Review each provider's service and privacy terms before adding an account.

The app persistently stores the following on your Mac:

- `~/Library/Application Support/TokenMeter/credentials.json`: API keys, OAuth access/refresh tokens, or browser-login tokens/session cookies. This is **plaintext JSON**, not Keychain storage. On write, the app sets the directory to `0700` and file to `0600`; the macOS user and any local software able to read this file should still be treated as able to access the credentials.
- `~/Library/Application Support/TokenMeter/subscriptions.json`: subscription names, providers, authentication methods, enabled state, colors, and other metadata. It should not contain credentials.
- `UserDefaults`: refresh and notification preferences and thresholds, appearance, launch-at-login state, notification de-duplication records, and panel sizing.
- WebKit's default website-data store: sites used for embedded login can retain cookies, local storage, and other website data for later sign-in. The app can clear relevant site data when needed.

Do not publish these files, screenshots, logs, or browser exports. See [SECURITY.md](SECURITY.md) for security boundaries and reporting instructions.

## Development and contributing

The project uses Swift 6, SwiftUI, AppKit, ServiceManagement, and UserNotifications, with no third-party dependencies. The offline test requirement and contribution process are in [CONTRIBUTING.md](CONTRIBUTING.md); provider changes must also follow the [provider development guide](docs/provider-development.md). Public reports belong in GitHub Issues—never attach API keys, tokens, cookies, or a complete credential file.

## License

[GPL-3.0](./LICENSE)
