# Repository Guidelines

## Project Structure & Module Organization

This is a macOS SwiftUI menu-bar app built by the `TokenMeter` target in
`TokenMeter.xcodeproj` (Swift 6, macOS 14+).

- `TokenMeter/TokenMeterApp.swift` defines app and window entry points.
- `Models/` contains Codable domain types such as subscriptions and quotas.
- `Providers/ProviderDefinition.swift`, `ProviderRegistry.swift` and `UsageProvider.swift`
  are the shared provider contracts; `Providers/Common/` holds provider-agnostic
  machinery (HTTP, browser-session flow, relay balance definition).
- **`Providers/Extensions/<provider-id>/` is the single extension point for
  providers.** Each folder owns its stable IDs, login site, services, card
  renderer and catalog entry; adding a provider means adding that folder plus one
  line in `Providers/Extensions/ProviderCatalog.swift`.
- `Services/` owns local credential-file access and migration.
- `Store/` contains `UsageStore`, the shared app state and refresh orchestration.
- `Views/` contains SwiftUI screens and reusable view components.
- Provider PNG assets sit beside their code in `Providers/Extensions/<id>/`
  (`Resources/` only holds the app icon).

`TokenMeter/Providers/` and `TokenMeter/Tests/` are Xcode **file-system
synchronized groups**: new `.swift` and image files there are compiled and
bundled without editing `project.pbxproj`. Files anywhere else still have to be
registered in the project file by hand.

### Adding a provider

Shared code never switches on a provider. `ProviderRegistry` derives
`isSupported` / `authFlow` from the definition itself, the editor reads the
login/authorization declarations carried by each `AuthMethodDefinition`, and
`APIClient` takes the 401/403 semantics from the caller's `HTTPStatusPolicy`.
Supplier-specific historical identifiers likewise belong to the definition
(`legacyPlatformNames`, `AuthMethodDefinition.legacyIDs`), not to a shared table.
If adding a provider seems to require editing a shared file, that is a design
regression — discuss it instead. Full guide: `docs/provider-development.md`;
relay-specific playbook: `.pi/skills/add-relay-provider/SKILL.md`.

## Build, Test, and Development Commands

Open the project in Xcode with `open TokenMeter.xcodeproj`, or build from the
repository root:

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Use `-configuration Release` for an optimized build. `xcodebuild -list` shows
the available target and scheme names. Run the configured Swift Testing target
with:

```bash
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, one type per logical
responsibility, `UpperCamelCase` for types, and `lowerCamelCase` for properties
and methods. Prefer SwiftUI composition, `async`/`await`, value types, and
guard clauses. Match the concise switch-expression style already used in the
models. No formatter or linter configuration is checked in; keep formatting
Xcode-standard and make the smallest focused diff.

## Testing Guidelines

Tests use Swift Testing in the `TokenMeterTests` target. Keep files named
`*Tests.swift` under `TokenMeter/Tests/` and cover provider parsing, malformed
responses, and authentication failures. The existing suite exercises quota
kind compatibility, Kimi window mapping, deduplication, and missing data.
Run it with the `xcodebuild ... test` command above.

## Commits & Pull Requests

完成每个独立功能并通过针对性验证后，立即创建一个 Git commit。提交前检查
差异，只纳入该功能相关改动；用户已有、无关或尚未完成的改动必须保留在工作区，
不得混入提交。使用简短的祈使句作为提交主题（例如 `Add Kimi usage parsing`），
并保持不同功能分开提交。Pull request 应说明行为变化、受影响的 provider 或
view、验证命令；可见 UI 变化应附截图。绝不提交 API key、OAuth token 或其他凭据；
凭据应保存在应用管理的私有 `Application Support/TokenMeter/credentials.json`
文件中。

## Page Index

Use the following stable page IDs when referring to screens in tasks, issues, reviews, or implementation notes. These IDs describe user-facing screens, not reusable SwiftUI components.

| ID | Page name | SwiftUI entry point | How to open / notes |
| --- | --- | --- | --- |
| TM-01 | 概览面板（菜单栏） | `MenuBarView` | Click the TokenMeter menu-bar item. Shows all subscriptions, usage summaries, refresh status, and the add-subscription action. |
| TM-02 | 设置面板 | `SettingsPanel` | From TM-01, click the settings icon. This is an in-panel page; use “返回概览” to return to TM-01. |
| TM-03 | 选择供应商页面 | `MenuBarView` → `ProviderSelectionPage` | From TM-01, click “添加订阅”. Shows five provider cards in the menu panel. |
| TM-04 | 添加订阅配置页面 | `MenuBarView` → `SubscriptionEditorSheet` | Select a provider in TM-03, then configure its name and authentication inside the panel. |
| TM-05 | 编辑订阅配置页面 | `MenuBarView` → `SubscriptionEditorSheet` | From a subscription card in TM-01, click the card to edit its configuration directly. `SubscriptionEditorDraft` preserves unsaved configuration while the panel is hidden. |
| TM-06 | 状态预览覆盖层（仅 Debug） | `StatusPreviewOverlay` | From TM-02 → “预览状态” in Debug builds. This is an overlay for previewing normal, loading, authentication, error, low-balance, and empty states—not a production page. |

When a request names a page ID, first inspect the corresponding entry point above. `SubscriptionUsageView`, `PlatformLogo`, `StatusBadge`, and other smaller `View` types are shared components, not separate pages.

完成需求，构建一下项目，并重新启动APP。

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` + `docs/adr/`. See `docs/agents/domain.md`.
