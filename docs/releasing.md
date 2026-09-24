# 发版说明 / Releasing

版本号只有一个来源：仓库根目录的 `VERSION`。Xcode 工程里的
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`、以及最终打进包里的
`CFBundleShortVersionString` 全部由它派生——手工改 `project.pbxproj` 里的版本号
会在下一次同步时被覆盖。

一个版本对应三处同名约定：

- `VERSION` 里的一行版本号，例如 `0.3.0`；
- tag `v0.3.0`，必须是 `v$(cat VERSION)`；
- 发版提交的标题 `TokenMeter 0.3.0`。

发版是纯 tag 驱动：推 tag 之前先在 `main` 上把 CHANGELOG、`VERSION`、
Xcode 工程一次性改好并提交。本地打包与签名（`scripts/package-release.sh`）
见 [CONTRIBUTING.md](../CONTRIBUTING.md)，二者共用同一份版本号。

## 版本源与 `scripts/version.py`

| 位置 | 内容 | 谁写 |
| --- | --- | --- |
| `VERSION` | 一行版本号，结尾换行 | 发版时手工改，**唯一来源** |
| `TokenMeter.xcodeproj/project.pbxproj` | Debug 与 Release 两个配置的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | `python3 scripts/version.py` |
| `TokenMeter/Info.plist` | `CFBundleShortVersionString` = `$(MARKETING_VERSION)`，`CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)` | 手工改成变量引用后就不要再动 |

```bash
python3 scripts/version.py           # 按 VERSION 同步工程文件，并打印改了什么
python3 scripts/version.py --check   # 只校验不写；不一致时打印差异并 exit 1
```

- 无参数运行会把两个配置的 `MARKETING_VERSION` 设成 `VERSION` 的内容，
  `CURRENT_PROJECT_VERSION` 设成由版本号推导的整数 `major*10000 + minor*100 + patch`
  （`0.2.0` → `200`）。幂等，重复跑不产生新改动。
- `--check` 校验工程里的这两个值与 `VERSION` 一致，并确认 `TokenMeter/Info.plist`
  仍然引用 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`；不一致就打印
  人能看懂的差异并失败。`ci.yml` 每次都跑它，release workflow 在构建前也跑。

## CHANGELOG 条目格式

新条目写在 `CHANGELOG.md` 最上面，标题行固定为 `## <version> — <YYYY-MM-DD>`
（版本号不带 `v`，日期是发布当天），正文先一段 `**中文**`、再一段 `**English**`。
一个条目 = 从标题行到下一个以 `## ` 开头的行之前；GitHub Release 的正文就是从
这一段抽出来的。

```markdown
## 0.3.0 — 2026-09-25

**中文**

- 说明这次改了什么，以及用户能观察到的行为变化。

**English**

- What changed in this release, and the behavior a user can observe.
```

条目要在**打 tag 之前**写好并提交：workflow 在构建前就检查有没有这一条，
缺了会直接失败，而不是发一个正文不对的 Release。

## 发版步骤

```bash
# 1. 在 CHANGELOG.md 顶部写 ## 0.3.0 — <今天> 条目（中文 + English）
# 2. 改 VERSION：一行版本号，结尾换行
printf '0.3.0\n' > VERSION
# 3. 把版本同步进 Xcode 工程（Debug / Release 两个配置）
python3 scripts/version.py
# 4. 提交，标题就是 TokenMeter <version>
git add VERSION CHANGELOG.md TokenMeter.xcodeproj/project.pbxproj
git commit -m "TokenMeter 0.3.0"
git push origin main
# 5. 打 tag 并推——这一步触发发布
git tag -a v0.3.0 -m "TokenMeter 0.3.0"
git push origin v0.3.0
```

推 tag 之后 `Release` workflow（`.github/workflows/release.yml`）自动完成：

1. 跑测试套件（`xcodebuild ... test`）；
2. 用 `-configuration Release`、`ARCHS='arm64 x86_64'` 构建 universal 未签名包，
   并核对构建出的版本号与 `VERSION` 一致；
3. 打包 `TokenMeter-<version>-macos-universal.zip` 与同名 `.sha256`；
4. 发布 GitHub Release，标题 `TokenMeter <version>`，正文取自该版本的 CHANGELOG 条目。

发布资产由 workflow 独占，不要手工再传一个压缩包上去。

## 发布门禁

Release workflow 在构建前依次检查三件事，任一不通过就整轮失败：

| 门禁 | 检查什么 |
| --- | --- |
| tag 与 `VERSION` 一致 | tag 去 `v` 后必须等于 `VERSION` 的内容（字面比较），且形如 `MAJOR.MINOR.PATCH` |
| CHANGELOG 有该版本条目 | `CHANGELOG.md` 里存在以 `## <version>` 开头的标题行（版本号按字面匹配），且条目正文里 `**中文**` 与 `**English**` 两段都在 |
| 版本一致性 | `python3 scripts/version.py --check` 通过：工程里的版本号与 `VERSION` 一致、`Info.plist` 仍在引用那两个变量 |

失败意味着这一版的 tag 作废，按下一节改文件、重打 tag，不要绕过门禁发布。

`workflow_dispatch`（手工触发）可以针对已存在的 tag 重跑：

```bash
gh workflow run release.yml -f tag=v0.3.0
```

## 预发布（pre-release）

预发布把后缀整个写进 `VERSION`，tag 照旧是 `v$(cat VERSION)`——不是一个「干净的」
数字版本号。门禁比较的是字面值，`v0.3.0` 配 `VERSION` 里的 `0.3.0-beta.1` 会直接失败。

```bash
printf '0.3.0-beta.1\n' > VERSION
python3 scripts/version.py
git add VERSION CHANGELOG.md TokenMeter.xcodeproj/project.pbxproj
git commit -m "TokenMeter 0.3.0-beta.1"
git push origin main
git tag -a v0.3.0-beta.1 -m "TokenMeter 0.3.0-beta.1"
git push origin v0.3.0-beta.1
```

版本号里带 `-` 时 workflow 会自动把 Release 标成 pre-release（`gh release create
--prerelease`），因此它不会顶掉「Latest release」。CHANGELOG 的标题行照旧写
`## 0.3.0-beta.1 — <日期>`，与 `VERSION` 一致。

## 出错之后

**门禁没过**（tag 与 `VERSION` 不符、CHANGELOG 缺条目、版本不一致）：
改的是文件而不是 tag 内容——修好文件、提交到 `main`，再重打 tag。

```bash
git tag -d v0.3.0                     # 删本地 tag
git push origin :refs/tags/v0.3.0     # 删远端 tag
git tag -a v0.3.0 -m "TokenMeter 0.3.0"
git push origin v0.3.0
```

**构建或发布中途失败**：先修 `main` 上的文件（或删掉错的 tag 重打），然后用
`gh workflow run release.yml -f tag=v0.3.0` 重跑；workflow 会重新走测试与构建，
覆盖同名发布资产。

**已发布的 Release 正文要改**：正文来自 CHANGELOG，而 workflow 只在 Release
还不存在时写入。要连正文一起更新，先删掉再重跑：

```bash
gh release delete v0.3.0 --yes
gh workflow run release.yml -f tag=v0.3.0
```

`gh release delete --cleanup-tag` 会连 tag 一起删掉，删完记得按上面的步骤重打，
否则就没有 tag 可构建了。

不要为了摆脱门禁而手改 `project.pbxproj` 里的版本号，也不要手工上传资产：
两者都会让某个版本号后面的内容对不上。
