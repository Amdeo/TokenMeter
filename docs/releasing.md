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

一次发布产出两种下载（zip 与 DMG）、并在发布成功后把它推给应用内更新（Sparkle）：
zip 与 `.sha256` 由 workflow 打包，DMG 由 `scripts/dmg.sh` 产出，`appcast.xml`
由 workflow 自动写入。维护者侧要准备的只有一把 EdDSA 私钥，见
[应用内更新（Sparkle）](#应用内更新sparkle)。

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
2. 用 `-configuration Release`、`ARCHS='arm64 x86_64'` 构建 universal 包，
   并核对构建出的版本号与 `VERSION` 一致；
3. 由内向外做 ad-hoc 签名（`codesign --sign -`）：Sparkle 的 `Updater.app`、
   `Downloader.xpc`、`Installer.xpc`，然后是 `Sparkle.framework`，最后是 app 本身，
   收尾用 `codesign --verify --deep --strict` 自检；
4. 打包 `TokenMeter-<version>-macos-universal.zip` 与同名 `.sha256`；
5. 用 `scripts/dmg.sh` 从同一个 app 打出
   `TokenMeter-<version>-macos-universal.dmg`；
6. 发布 GitHub Release，标题 `TokenMeter <version>`，正文取自该版本的 CHANGELOG
   条目，三个资产（zip、`.sha256`、dmg）一起上传；
7. 发布成功后再把 zip 签名写进 `appcast.xml`，以 `github-actions[bot]` 身份提交到
   `main`（标题 `Offer <version> to Sparkle`），最后回读远端确认这一版真的在 feed 里。

发布资产由 workflow 独占，不要手工再传资产上去。第 7 步失败（缺
`SPARKLE_PRIVATE_KEY`、找不到 `sign_update`、推送没落到远端）会让整轮失败，但
Release 此时已经发布——补上缺的东西后用 `workflow_dispatch` 重跑即可，脚本与
feed 都对同版本幂等。

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

## DMG

```bash
scripts/dmg.sh <app 路径> [输出目录]
```

从已构建的 app 打出 `<输出目录>/TokenMeter-<version>-macos-universal.dmg`，
输出目录默认仓库根的 `dist/`。版本号读自 app 自己的 `Info.plist`
（`CFBundleShortVersionString`），不读 `VERSION`，因此包名不会和 app 本体各说各话。
卷名是「TokenMeter <version>」，卷里只有 `TokenMeter.app` 和指向 `/Applications`
的符号链接——拖进去就算装完，这也是 DMG 相对 zip 的全部好处。

脚本不挂载镜像、不用 AppleScript、不碰 Finder（`ditto` + `hdiutil create
-format UDZO -imagekey zlib-level=9`），CI runner 上没有登录的桌面会话也能跑。
可重复执行：同名 DMG 先删再建，失败会清掉 staging 目录与半成品。

## 应用内更新（Sparkle）

应用内更新走 [Sparkle](https://github.com/sparkle-project/Sparkle)（SPM 依赖，
`upToNextMajorVersion` / `minimumVersion = 2.6.0`，封装在
`TokenMeter/Services/AppUpdate.swift`）。更新源是 `main`
分支上的 `appcast.xml`，由 `Info.plist` 的 `SUFeedURL` 指向
`https://raw.githubusercontent.com/Amdeo/TokenMeter/main/appcast.xml`。
界面入口两个：菜单栏右键菜单的「检查更新…」，和设置窗口「应用」页版本行右侧的按钮。
自动检查开着（`SUEnableAutomaticChecks`），间隔 `SUScheduledCheckInterval=7200`
（2 小时），但 `SUAutomaticallyUpdate=false`——下载安装前仍要用户点头。

feed 里的 `<enclosure>` 指向 **zip**（`releases/download/v<version>/…-macos-universal.zip`）
而不是 DMG：Sparkle 要的是能自己展开的压缩包，DMG 只是给人手动下载用的。

### 信任链只有一把 EdDSA 密钥

Sparkle 只安装由 `Info.plist` 里 `SUPublicEDKey` 对应私钥签过名的压缩包，
**这就是没有 Developer ID 也能安全自更新的全部依据**：app 自己只有 ad-hoc
签名，Apple 什么都没背书，但更新路径照样可验证。公钥
`DXI37+ptRYBAl3kqaHRlCOOo2SZmPfEXkHsDzTXnnQo=` 可以公开；私钥在两处：

| 位置 | 谁用 |
| --- | --- |
| `~/.sparkle-keys/tokenmeter-ed25519.key`（600 权限，在仓库外） | 维护者本机跑 `scripts/appcast.py --private-key` |
| GitHub 仓库 secret `SPARKLE_PRIVATE_KEY` | CI，经 stdin 交给 Sparkle 的 `sign_update` |

**公钥一旦随某个版本发布就不能再换**：换了之后已装的旧版本会拒收所有新包，用户只能
手动重装一次。私钥丢了同样是灾难——现有用户再也收不到更新。备份私钥，别提交它。

签名工具是 Sparkle 自带的命令行工具 `sign_update`，随 SPM 依赖被 Xcode 下到
DerivedData；`scripts/appcast.py` 按 `--sign-update` 参数、`SIGN_UPDATE` 环境变量、
再在 DerivedData 与 `build/` 下找的顺序解析它。

### 本地重跑

```bash
python3 scripts/appcast.py <version> <zip 路径> <下载 URL> \
  --private-key ~/.sparkle-keys/tokenmeter-ed25519.key
```

`<version>` 必须与 CHANGELOG 里 `## <version>` 的条目一致：条目正文（到下一个
`## ` 之前）会转成 HTML 放进更新窗口的说明，所以缺条目就直接失败。`<下载 URL>`
写进 `<enclosure url>`，`length` 与 `sparkle:edSignature` 由签名得出，
`sparkle:minimumSystemVersion` 固定 `14.0`。私钥除了 `--private-key`，也可以放在
`SPARKLE_PRIVATE_KEY` 环境变量里（两者都没有时交给 `sign_update` 自己找）。
幂等：feed 里已有同版本就什么都不做；脚本只改 `appcast.xml`，不做任何 git 操作——
CI 里的提交与推送由 workflow 负责。

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

**Sparkle 的 feed 不区分 beta**：版本号里带 `-` 不会让这一版留在更新通道之外，
workflow 照样会把它写进 `appcast.xml`，装了任何已发布版本的人在下次自动检查时就会
收到它。pre-release 只影响 GitHub 上谁被顶掉，不影响谁能收到更新——不想让人收到，
就不要推这个 tag。

构建号只取版本号的数字部分（`0.3.0-beta.1` 与 `0.3.0` 都是 `300`），而 Sparkle
比的是构建号：装过 `0.3.0-beta.1` 的机器**不会**被提示升到 `0.3.0`，只能手动重装。
想让 beta 被后续版本顶掉，就把 beta 的号往前放一位（例如 `0.3.1-beta.1`）。

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
覆盖同名发布资产。对 `appcast.xml` 也安全：feed 里已有这一版就不再插条目，也不会
多出一次提交（`git diff --cached` 为空时那一步直接跳过）。

**feed 里的说明写错了**：说明是插入时从 CHANGELOG 转出来的快照，改 CHANGELOG 不会
回头改 feed。要改就手工编辑 `appcast.xml` 里那条 `<description>` 并提交到 `main`，
别再跑一次 `scripts/appcast.py`——它对同版本是空操作。

**已发布的 Release 正文要改**：正文来自 CHANGELOG，而 workflow 只在 Release
还不存在时写入。要连正文一起更新，先删掉再重跑：

```bash
gh release delete v0.3.0 --yes
gh workflow run release.yml -f tag=v0.3.0
```

`gh release delete --cleanup-tag` 会连 tag 一起删掉，删完记得按上面的步骤重打，
否则就没有 tag 可构建了。

不要为了摆脱门禁而手改 `project.pbxproj` 里的版本号，也不要手工上传资产：
两者都会让某个版本号后面的内容对不上。修改 `Info.plist` 里的 `SUPublicEDKey`
同样要停手——那是一次性决定，换了就等于切断所有已安装版本的更新。
