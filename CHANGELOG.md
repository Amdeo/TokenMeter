# Changelog

All notable changes are documented here. Each entry is bilingual — 中文在前，English 在后.

## 0.3.0 — 2026-09-25

**中文**

**悬浮条（TM-07）**

- 新增屏幕边缘的用量悬浮条：静止时是一条细带，鼠标划过展开成一排环，悬停看详情卡片、点击刷新该订阅、拖动可贴到屏幕边缘或自由悬浮。默认关闭，一个环都没有时自动隐藏。
- 每条订阅自己带悬浮条设置（是否上条、环追踪哪个额度、环的颜色），与卡片样式、进度条配色存在同一层：删除订阅会一并带走，不会在 `UserDefaults` 里留下孤儿键。「谁在条上」只在 `RailEntryBuilder` 一处判定。
- 显示设置分成「显示 / 位置 / 形状 / 环上画什么」四组：环间距与圆角端、倒数、数字位置、百分比、稍细的第二圈、窗口时钟弧、取数中的活动动画、收起细条的告警色。
- 悬浮条有自己的配色（深色 / 浅色 / 跟随主题，默认深色），与 app 主题互不影响；开着玻璃特效时不强钉外观。
- 环上的品牌标记用单色模板图，按用量状态染色：七个 Lobe Icons SVG，加 APIKEY.FUN 的单色 PNG 兜底；其余三个中转站的渐变 logo 在 18pt 下会糊成一团，仍用 SF Symbols。
- 悬浮条右键菜单独立成可测的 `RailContextMenu`，贴边时多一个「常显示」；条上的菜单只管条自己，不再有「打开 TokenMeter」。
- 详情卡片补上总使用量一行，金额改用紧凑写法（`Quota.compactText`，与面板的 Siyu 卡片共用）；卡片轮廓改成一条连续路径，根部不再有两道竖缝。
- 尺寸预算（`RailMetrics`）与环上画什么（`RailRingOptions`）分成两层：窗口 frame、命中区与绘制读同一份，不再出现「窗口按 A 算、绘制按 B 画」。

**独立设置窗口（TM-02 / TM-03 / TM-04 / TM-05）**

- 设置从面板搬进独立窗口：左侧 source list 分「应用 / 订阅 / 其他」，右侧一次一页；「订阅」组只列用户真的添加过的订阅，按自己的顺序排列。
- 三个入口：面板头部齿轮、菜单栏图标右键菜单、悬浮条右键菜单。
- 窗口用 `SettingsGroup` + `SettingsRow` 卡片脚手架搭出来，沿用面板的 TM 配色而不是系统色。
- 订阅编辑页新增「悬浮条」组（是否上条、环追踪哪个额度、环的颜色）与「显示顺序」组（箭头逐格调整，拖放一次跨多格）。
- 编辑页底栏钉在自己底部（只有这一页自己滚），主按钮只留「保存」，删除挪到另一头并保留二次确认；卡片里不放控件的裸文本补上统一内边距。
- Debug 的状态预览（TM-06）随设置一起搬走，改挂到菜单栏右键菜单。

**面板收敛成单页（TM-01）**

- 菜单面板只留概览一页，二级页、编辑草稿与按页高度记忆一并删掉；以前手动拖出的高度仍经 `panel.overviewHeight` 生效。
- 「添加订阅」与点订阅卡片改为打开设置窗口的对应页；数据迁移成为窗口里的一页。
- 只为「第二个宿主」存在的旋钮（`heightRoute`、`showsBackButton`、`showsCancel`、页面 chrome 常量、供应商选择页的返回按钮）随第二个宿主一起删掉。

**卡片与外观**

- 订阅卡片样式可选择（标准 / 紧凑），外观页带实时轮播预览；进度条配色与余额配色按样式分开保存，解码到未知样式时回退标准样式，旧订阅数据不丢。
- 外观页可配置余额颜色；颜色目标只要有内容就追加「默认颜色」兜底行，纯余额卡片也能设置。
- Kimi 月额度成为独立的额度行，带进度条与重置时间，状态判定也把它算进去；OpenCode Go 卡片显示重置时间；长按卡片显示额度重置倒计时（计时改由可取消的任务驱动，指针离开或位移超过 10pt 即作废）。
- 紧凑样式抽成共享的 `CompactUsageCard`（Kimi、OpenCode Go、DeepSeek 与各中转站的余额卡片共用），供应商只组装数据行；紧凑余额卡压成一行（图标 + 名称 + 金额）。
- 切换卡片样式不改变行高与面板高度；卡片头部去掉状态点，取值旁边冗余的「已用」字样也去掉了。

**面板与菜单栏修复**

- 菜单栏图标可设为「点击不弹面板」，普通左击改弹右键那个菜单，关掉时把已弹出的面板收掉；点图标的判定抽成 `StatusItemClick`。
- 面板窗口尺寸收敛到单一来源（`navigation.displayedSize`），并加屏幕限高：高度不超过锚定屏幕 `visibleFrame`，且限高只影响显示、不写回记忆高度。
- 宿主视图改成四边约束钉在容器上、清空 `NSHostingView` 的 `sizingOptions`，并在窗口 frame 变化后显式推动一次布局求解；修掉内容贴底、顶部露出空白条、首尾被裁（返回按钮看不到也点不到）、以及设置页脚注异步到达后高度错位。
- 面板支持在每一页拖拽调整大小；概览的订阅行卡片自己读快照，快照写入不再触发整块面板重建。
- 右击菜单加退出确认，退出按钮改成亮红；额度配色行默认折叠；菜单头部控件收紧，头部「添加订阅」按钮去掉常态背景。

**发版流程与工具**

- 版本号收敛到根目录 `VERSION` 单一来源：`scripts/version.py` 把它写进 Xcode 工程的 Debug 与 Release 两个配置（`MARKETING_VERSION` 取版本号，`CURRENT_PROJECT_VERSION` 取 `major*10000 + minor*100 + patch`），`--check` 给 CI 与发版门禁校验。
- 发版即推 tag：tag 形如 `v0.3.0` 且必须等于 `v$(cat VERSION)`，发布提交标题为 `TokenMeter 0.3.0`；tag 触发 release workflow，跑测试、出 universal 包、附 SHA-256 校验和并建 GitHub Release。发版流程与门禁见 `docs/releasing.md`。
- `CHANGELOG.md` 条目改为中英双语，Release 说明直接取对应版本这一节。
- 中转站开发 skill 增加本地取证工具：通过 Chrome CDP（9222 端口）探测中转站站点，并先用 HTML 预览卡片再写 Swift。
- `AGENTS.md` 更新页面索引（TM-02 / TM-06 的归属变化与新增的 TM-07）、四个文件系统同步组，以及悬浮条「谁在条上」只有一个判定处、悬浮条呈现分两层这两条容易踩错的约定。

**English**

**Rail (TM-07)**

- Added a screen-edge usage rail: a thin strip at rest that expands into one ring per subscription, with a detail card on hover, a refresh of that subscription on click, and drag-to-dock. Off by default, and hidden when nothing is left on it.
- Gave each subscription its own rail settings (whether it appears, which quota the ring tracks, the ring's colour), stored on the subscription next to its card style and quota colours, so deleting one takes its settings with it instead of leaving orphaned defaults keys; "who is on the rail" is decided in `RailEntryBuilder` alone.
- Grouped the rail's display settings into 显示 / 位置 / 形状 / 环上画什么: ring spacing and round ends, counting down, figure placement, percentages, a thinner second ring, a window-clock arc, a fetching animation, and the collapsed strip's alert colour.
- Let the rail pick its own colour scheme (dark / light / follow the theme, dark by default) independently of the app's theme, and stopped pinning the appearance while the glass material is on.
- Shipped monochrome template marks for the rings, tinted by usage state: seven Lobe Icons SVGs plus a monochrome PNG fallback for APIKEY.FUN; the three remaining relay providers keep their SF Symbols because their gradient logos turn to mush at the rail's 18pt mark size.
- Moved the rail's context menu into `RailContextMenu` so it is testable, with a 常显示 toggle while docked; the rail's menu no longer offers 打开 TokenMeter.
- Added the overall usage row to the detail card with compact amounts (`Quota.compactText`, shared with the panel's Siyu card), and drew the card's outline as one continuous path so the pointer no longer leaves two vertical seams.
- Split the rail's presentation into two layers — the size budget (`RailMetrics`) and what each ring draws (`RailRingOptions`) — so the window frame, the hit areas and the drawing all read the same answer.

**A standalone settings window (TM-02 / TM-03 / TM-04 / TM-05)**

- Moved settings out of the panel into a standalone window: a source list on the left grouped into 应用 / 订阅 / 其他, one pane at a time on the right, with the 订阅 group listing only subscriptions the user has actually added, in their own order.
- Kept three ways in: the gear in the panel header, the menu-bar item's right-click menu, and the rail's context menu.
- Built the panes from `SettingsGroup` + `SettingsRow`, keeping the app's TM colours rather than system ones.
- Added a 悬浮条 group (show on the rail, which quota the ring tracks, the ring's colour) and a 显示顺序 group (arrow buttons for exact steps, drag-and-drop for long moves) to the subscription editor.
- Pinned the editor's footer (only that page scrolls), left 保存 as its only primary button, moved delete to the other end behind a second confirmation, and gave bare text inside the cards a shared inset.
- Moved the Debug status preview (TM-06) out of the panel's settings route and onto the menu-bar right-click menu.

**The menu panel as a single overview page (TM-01)**

- Reduced the menu panel to its overview page, dropping the routes, the editor draft and the per-route height memory; a height dragged out before still applies through `panel.overviewHeight`.
- Pointed 添加订阅 and the subscription cards at the matching settings-window pane, and made the migration flow a page of that window.
- Removed everything that existed only to serve a second host: `heightRoute`, `showsBackButton`, `showsCancel`, the page-chrome constants and the provider picker's back button.

**Cards and appearance**

- Added selectable subscription card styles (standard / compact) with a live carousel preview, storing progress and balance colours per style and falling back to standard for unknown decoded values so existing subscriptions survive.
- Added an appearance page with configurable balance colours, appending a 默认颜色 fallback row whenever there is something to colour, so pure-balance cards can be themed too.
- Made Kimi's monthly quota a proper quota row with a progress bar and reset time (and counted it towards the status); showed OpenCode Go reset times on the card; revealed a quota reset countdown while long-pressing a card, tracked by a cancellable task that is abandoned once the pointer leaves or moves more than 10pt.
- Extracted the compact style into the shared `CompactUsageCard` (used by Kimi, OpenCode Go and the balance cards of DeepSeek and every relay), with providers assembling only the data rows; the compact balance card is a single line — icon + name + amount.
- Kept the row height and panel height unchanged across card styles, dropped the card header's status dot, and removed the redundant 已用 prefix from card values.

**Panel and menu-bar fixes**

- Added a menu-bar setting to skip the panel (a plain left click then opens the menu) and pulled the click rule into `StatusItemClick`.
- Gave the panel window a single size source (`navigation.displayedSize`) plus a screen limit that never writes back to the remembered height.
- Pinned the hosted content view to its container with four-edge constraints, cleared `NSHostingView.sizingOptions`, and forced one layout solve after the window frame changes — fixing content stuck to the bottom, a blank strip at the top, clipped headers (a back button you could neither see nor click), and the settings footer's late arrival shifting the height.
- Supported panel resizing on every page, and moved the snapshot read into the overview row card so a snapshot write no longer rebuilds the whole panel.
- Added a quit confirmation to the right-click menu with a bright-red quit button, collapsed the quota colour rows by default, and tightened the menu header controls.

**Release process and tooling**

- Made `VERSION` at the repository root the single source of the version: `scripts/version.py` writes it into the project's Debug and Release configurations (`MARKETING_VERSION` from the version, `CURRENT_PROJECT_VERSION` as `major*10000 + minor*100 + patch`), and `--check` gates both CI and the release workflow.
- Made releasing a tag push: the tag (e.g. `v0.3.0`) must equal `v$(cat VERSION)`, the release commit is titled `TokenMeter 0.3.0`, and the tag runs the release workflow that tests, builds the universal archive, writes the SHA-256 checksum and publishes the GitHub Release. The process and its gates are documented in `docs/releasing.md`.
- Turned `CHANGELOG.md` entries bilingual, with the Release notes taken from the matching version's entry.
- Gave the add-relay-provider skill a local evidence path: probe relay sites through Chrome CDP (port 9222), and preview cards in HTML before writing Swift.
- Updated `AGENTS.md`: the page index (TM-02 / TM-06 moved, TM-07 added), the four file-system synchronized groups, and the two conventions that are easy to get wrong later — that "which subscriptions are on the rail" is decided in one place, and that the rail's presentation is two layers.

## 0.2.0 — 2026-09-13

**中文**

**新增**

- 新增 Claude（OAuth 授权码，Pro/Max 套餐额度窗口）与 OpenAI Codex（设备 OAuth，Codex 额度窗口）供应商。
- 新增思语 API 中转站供应商，带余额与日 / 周 / 月套餐窗口。
- 供应商改为按文件夹扩展的扩展点：每个供应商在 `Providers/Extensions/<id>/` 下自持稳定 ID、登录站点、授权处理、卡片渲染与图标，新增一个供应商 = 新建一个文件夹 + 在 `ProviderCatalog` 里加一行；同时给出可直接复制的模板、供应商开发指南与添加中转站的 skill。
- 发布改由 tag 驱动的 GitHub Actions workflow（`Release`）完成：跑测试、构建 universal 未签名归档、写 SHA-256 校验和，并把两者附到 GitHub Release；签名 / 公证的包仍在本地构建。

**变更**

- 各中转站合并成一份站点驱动的实现；共享机制从应用层的 `Services/` 移到 `Providers/Common/`。
- 恢复订阅拖放排序并带动画落位，同时调整概览头部图标间距与卡片内边距。
- **发布归档改名为 `TokenMeter-<version>-macos-universal.zip`，并附同名 `.sha256` 文件一起发布。**
- 把添加订阅、设置与退出收进菜单栏图标的右键菜单；概览底部的操作行删除，同步状态移到头部服务数量旁边。
- 思语 API 套餐改为日 / 周 / 月三个额度窗口并带重置提示，不再是单个月度行；README 的供应商表格也补上思语。
- 浅色外观可选磨砂玻璃面板背景；默认仍是纯白。
- 通知授权改为启动时请求一次，不再在概览面板里弹，且只在开了提醒、系统又尚未决定时才请求；设置面板仍显示授权状态与拒绝原因。
- 写清安装路径，包括已发布的未签名 v0.1.0 归档，以及它与 `main` 的区别。
- 修正公开 clone 地址，并写明从源码构建需要 Xcode 26+。
- 记录当前的提醒范围、仅中文界面、本地持久化、明文凭据存储、WebKit 站点数据持久化与公开 issue 流程。
- 新增安全报告指引、贡献指引，以及禁止贴凭据的 issue / pull request 模板。
- 固定 CI 依赖版本、加入校验过的 Gitleaks 扫描、universal 发布打包，以及原创应用图标。
- 界面上讲清已用额度的百分比、真实同步状态、通知权限与本地明文存储；补上应用版本与 issue 链接。

**修复**

- 思语的套餐窗口改用显式 key 分组而不是显示名，同名（或没名字）的两个套餐不再并成一段；API 没有上限的窗口直接不显示，不再画成用尽的 `$0.00 / $0.00` 行。
- 通知授权被拒（未签名构建）时把系统给的原因显示出来，不再让「允许通知」按钮看起来没反应。
- 阻止测试宿主初始化生产用的 store、窗口与后台刷新。
- OAuth 表单状态改由授权数据推导，不再依赖状态文案；切换授权方式时清掉旧状态。
- 已取消的刷新回调不再覆盖更新的状态，也不再清掉更新的刷新任务。
- 订阅元数据损坏时保留原文件、恢复前禁止改配置，并把持久化错误连同「重新加载」操作一起暴露出来。
- 打包时拒绝重复打包已发布的版本号，并打印源修订号，未发布的 `main` 内容不会被塞进已发布的版本号里。
- 修正编辑器和 store 重构后 `PONYTAIL-DEBT.md` 里过时的行号引用。
- 写明未签名构建首次启动的具体步骤，包括校验校验和之后移除 quarantine。

**English**

**Added**

- Added Claude (OAuth authorization code, Pro/Max plan quota windows) and OpenAI Codex (device OAuth, Codex quota windows) providers.
- Added the Siyu API relay provider with balance and daily/weekly/monthly plan windows.
- Made providers a folder-based extension point: each provider owns its stable IDs, login site, authorization handlers, card renderer, and icon under `Providers/Extensions/<id>/`, so adding one takes a new folder plus a single line in `ProviderCatalog`; shipped a copy-ready template, the provider development guide, and an add-relay skill.
- Published releases from a tag-driven GitHub Actions workflow (`Release`) that runs the test suite, builds the universal unsigned archive, writes the SHA-256 checksum, and attaches both to the GitHub Release; signed/notarized packages are still built locally.

**Changed**

- Merged the relay providers into one site-driven implementation; the shared machinery now lives in `Providers/Common/` instead of the app-level `Services/` layer.
- Restored subscription drag-to-reorder with animated drop placement, and balanced the overview header icon spacing and card insets.
- **Release archives are now named `TokenMeter-<version>-macos-universal.zip` and published with a matching `.sha256` file.**
- Moved add-subscription, settings, and quit into a right-click menu on the menu-bar icon; the overview's bottom action row is gone and the synchronization status now sits next to the service count in the header.
- Showed Siyu API plans as daily, weekly, and monthly quota windows with reset hints instead of a single monthly row, and listed Siyu in the README provider tables.
- Added an opt-in frosted-glass panel background for light appearance; the light panel is plain white by default.
- Requested notification authorization once at launch instead of prompting in the overview panel, and only when alerts are enabled and the system has not decided yet; the settings panel still reports status and refusal reasons.
- Clarified installation paths, including the published unsigned v0.1.0 archive and the distinction between that release and `main`.
- Corrected the public clone URL and documented the Xcode 26+ source-build requirement.
- Documented the current notification scope, Chinese-only UI, local persistence, plaintext credential storage, persistent WebKit site data, and public issue workflow.
- Added security-reporting guidance, contribution guidance, and public issue/pull-request templates that prohibit sharing credentials.
- Added pinned CI dependencies, verified Gitleaks scanning, universal release packaging, and an original application icon.
- Clarified used-quota percentages, actual synchronization state, notification permission, and local plaintext storage in the UI; added app version and issue links.

**Fixed**

- Grouped Siyu API plan windows by an explicit key instead of the displayed plan name, so two plans with the same name (or no name) stay separate sections, and omitted windows the API does not cap instead of rendering them as exhausted `$0.00 / $0.00` rows.
- Surfaced the system's reason when notification authorization is refused (unsigned builds), instead of leaving the allow-notifications button apparently inert.
- Prevented the test host from initializing production stores, windows, or background refreshes.
- Derived OAuth form state from authorization data rather than status-message wording and cleared stale state when switching methods.
- Prevented cancelled refresh completions from overwriting newer state or clearing a newer refresh task.
- Preserved corrupt subscription metadata, blocked configuration mutations until recovery, and exposed persistence errors with a reload action.
- Refused to repackage an existing release version and printed the source revision at package time, so unreleased `main` content cannot be shipped under a released version number.
- Corrected stale `PONYTAIL-DEBT.md` line references after the editor and store refactors.
- Documented the concrete first-launch steps for the unsigned build, including quarantine removal after checksum verification.

## 0.1.0 — 2026-09-08

**中文**

首个公开发布版本。发布说明与构建产物见 GitHub 上的 `v0.1.0` Release。

**English**

First public release. See the linked GitHub release for its published notes and assets.
