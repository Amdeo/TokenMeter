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
- `Rail/` contains the screen-edge floating rail (TM-07): placement and
  persistence, the window and its drag/docking, the rings, and the hover card.
  Provider marks are monochrome SVGs in `Rail/Marks/` (see its `CREDITS.md`);
  a brand with no vector logo can ship a monochrome PNG there instead, which
  `RailMarkStore` accepts as a fallback after `.svg`.
  It also holds `SubscriptionRailSection`, the per-subscription rail settings
  (TM-04/TM-05): whether that subscription shows on the rail, which quota its
  ring tracks, and the ring's colour.
- `Settings/` contains the standalone settings window (TM-02): the window
  controller, the sidebar navigation, and the grouped-card scaffold every pane
  is built from.
- Provider PNG assets sit beside their code in `Providers/Extensions/<id>/`
  (`Resources/` only holds the app icon).

`TokenMeter/Providers/`, `TokenMeter/Rail/`, `TokenMeter/Settings/` and
`TokenMeter/Tests/` are Xcode **file-system synchronized groups**: new `.swift`
and image files there are compiled and bundled without editing
`project.pbxproj`. Files anywhere else still have to be registered in the
project file by hand — and removing a file from a non-synchronized directory
means removing its three `project.pbxproj` entries too.

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
| TM-01 | 概览面板（菜单栏） | `MenuBarView` | Click the TokenMeter menu-bar item. **面板只有这一页**：订阅列表、用量摘要、同步状态。头部的「添加订阅」与点订阅卡片都打开 TM-02 的对应页，面板本身不再有二级页。 |
| TM-02 | 设置窗口 | `SettingsWindowView` / `SettingsWindowController` | 独立窗口，不是面板里的一页。入口：TM-01 头部的齿轮、TM-01 里的「添加订阅」与订阅卡片、菜单栏右键菜单的「设置…」与「添加订阅」、悬浮条右键菜单的「设置…」。左侧 source list 分「应用 / 订阅 / 其他」，订阅分组只列**已添加的**订阅。 |
| TM-03 | 选择供应商页面 | `SettingsWindowView` → `ProviderSelectionContent` | TM-02 →「添加订阅…」。显示全部供应商卡片。 |
| TM-04 | 添加订阅配置页面 | `SettingsWindowView` → `SubscriptionEditorContent` | 在 TM-03 里选中一个供应商之后。 |
| TM-05 | 编辑订阅配置页面 | `SettingsWindowView` → `SubscriptionEditorContent` | 从 TM-01 的订阅卡片、或 TM-02 侧边栏的订阅行进入。`SubscriptionEditorDraft` 在侧边栏来回切换时保留未保存的配置。 |
| TM-06 | 状态预览覆盖层（仅 Debug） | `StatusPreviewOverlay` | From the menu-bar item's right-click menu → “预览状态” in Debug builds. This is an overlay for previewing normal, loading, authentication, error, low-balance, and empty states—not a production page. |
| TM-07 | 悬浮条（贴边 / 悬浮） | `RailView` / `RailWindowController` | 打开「TM-02 → 悬浮条 → 显示悬浮条」后出现在屏幕边缘。鼠标划过展开，悬停某个环看详情卡片，点击刷新该订阅，拖动可贴到屏幕边缘或自由悬浮，右键出菜单。默认关闭。条上出现哪些订阅由每条订阅自己的「悬浮条」配置决定（`Subscription.rail.showsInRail`）；一个环都没有时条隐藏。 |

TM-03 / TM-04 / TM-05 的正文视图（`ProviderSelectionContent`、`SubscriptionEditorContent`、
`SubscriptionAppearanceContent`、`MigrationPanel`）都**只在设置窗口里用**。它们曾经由面板的
二级页宿主，那时靠 `heightRoute` / `showsBackButton` / `showsCancel` 之类的旋钮区分两个宿主；
面板的二级页删掉之后，那些旋钮也一并消失了——面板只有概览上报高度（`reportsIntrinsicPanelHeight`），
窗口里的子页不上报。不要再为「另一个宿主」加回这些旋钮。

每条订阅在悬浮条上的呈现（是否显示、环追踪哪个额度、环的颜色）存在**订阅自己身上**
（`Subscription.rail`，`SubscriptionRailSettings`），与卡片样式、进度条配色同一层：
编辑页改的是草稿，保存订阅时才落盘。条的长度、点击落在哪个环上、窗口尺寸全部读
`RailEntryBuilder.railSubscriptions(from:)`——「谁在条上」只有这一个判断处，
不要在别处再按 `store.subscriptions` 算环数或索引。

条本身的呈现分两层：**尺寸预算**（环间距、是否画百分比、数字在环上方、圆角端）由
`RailMetrics` 承载，窗口 frame、命中区与绘制必须读同一份（`SettingsStore.railMetrics`）；
**环上画什么**（倒数、第二圈、窗口时钟外弧、活动动画、细条告警色）由 `RailRingOptions`
承载（`SettingsStore.railRingOptions`）。不要把这两层的成员再拆回散落的常量——
窗口按 A 算、绘制按 B 画就是这个仓库反复修过的错位。

When a request names a page ID, first inspect the corresponding entry point above. `SubscriptionUsageView`, `PlatformLogo`, `StatusBadge`, and other smaller `View` types are shared components, not separate pages.

完成需求，构建一下项目，并重新启动APP。

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature-slug>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` + `docs/adr/`. See `docs/agents/domain.md`.
