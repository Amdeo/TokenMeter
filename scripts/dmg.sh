#!/bin/bash
#
# 用法：scripts/dmg.sh <app 路径> [输出目录]
#
#   从已构建的 TokenMeter.app 打出可分发的磁盘映像：
#
#       <输出目录>/TokenMeter-<version>-macos-universal.dmg
#
#   输出目录默认是仓库根的 dist/。版本号读自 app 自己的 Info.plist
#   （CFBundleShortVersionString），不读 VERSION 文件——包名和 app 本体因此不会
#   各说各话。可重复执行：同名 DMG 先删再建。
#
#       scripts/dmg.sh /tmp/dd/Build/Products/Release/TokenMeter.app
#       scripts/dmg.sh build/release-derived-data/Build/Products/Release/TokenMeter.app dist
#
# 卷名是「TokenMeter <version>」，卷里只有两样东西：TokenMeter.app，和指向
# /Applications 的符号链接——把 app 拖进去就算装完。
#
# 这个 app 没有 Apple Developer ID 签名、也没有公证，因为维护者不是苹果开发者。
# macOS 首次打开会拦下来（「无法验证开发者」或「已损坏」），用户得自己放行：
# 右键 app →「打开」，或到「系统设置 → 隐私与安全性」点「仍要打开」。这是有意的
# 取舍，不是打包漏了一步；Sparkle 的自动更新只要求本机 ad-hoc 签名（见
# .github/workflows/release.yml），与本脚本无关。
#
# 打包全程不碰 Finder、不跑 AppleScript、也不挂载镜像：CI runner 上没有登录的
# 桌面会话，摆图标那套只会在那里失败。hdiutil 直接由 staging 目录建 UDZO
# （zlib-level 9），因此不存在需要卸载的临时挂载点——失败留下的只有 staging 目录
# 和半个 DMG，由 trap 一并清掉。

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

usage() {
    printf '用法：%s <app 路径> [输出目录]\n' "$SCRIPT_NAME" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf '缺少命令：%s\n' "$1" >&2
        exit 1
    }
}

require_command hdiutil
require_command ditto
require_command /usr/libexec/PlistBuddy

# 相对路径按调用者的当前目录解析，之后一律用绝对路径，免得中途 cd 出岔子。
APP_PATH="$(cd "$1" 2>/dev/null && pwd)" || {
    printf 'app 不存在：%s\n' "$1" >&2
    exit 1
}
readonly APP_PATH
readonly PLIST_PATH="$APP_PATH/Contents/Info.plist"
[[ -f "$PLIST_PATH" ]] || {
    printf '不是 app bundle（缺 Contents/Info.plist）：%s\n' "$APP_PATH" >&2
    exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH" 2>/dev/null || true)"
VERSION="${VERSION//[[:space:]]/}"
[[ -n "$VERSION" ]] || {
    printf '读不到 CFBundleShortVersionString：%s\n' "$PLIST_PATH" >&2
    exit 1
}
readonly VERSION

readonly APP_NAME="$(basename "$APP_PATH")"
readonly VOLUME_NAME="TokenMeter $VERSION"
readonly DMG_NAME="TokenMeter-${VERSION}-macos-universal.dmg"

OUTPUT_ARG="${2:-$ROOT_DIR/dist}"
mkdir -p "$OUTPUT_ARG"
readonly OUTPUT_DIR="$(cd "$OUTPUT_ARG" && pwd)"
readonly DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

STAGING=""
cleanup() {
    local status=$?
    # trap 在 set -e 下同样会中途夭折，而清理恰恰不能因为清不掉某样东西就走人。
    set +e
    [[ -n "$STAGING" ]] && rm -rf "$STAGING"
    if (( status != 0 )); then
        rm -f "$DMG_PATH"
        printf '失败：已清理 staging 目录与未完成的 DMG。\n' >&2
    fi
    exit "$status"
}
trap cleanup EXIT

printf '打包 TokenMeter %s\n' "$VERSION"
printf '  app  %s\n' "$APP_PATH"
printf '  输出 %s\n' "$DMG_PATH"

# staging 放临时目录：不污染输出目录，也避免和同名残留目录打架。
TMP_ROOT="${TMPDIR:-/tmp}"
STAGING="$(mktemp -d "${TMP_ROOT%/}/tokenmeter-dmg.XXXXXX")"

# ditto（而不是 cp -R）是为了原样带上 bundle 里的符号链接、扩展属性与资源分支。
ditto "$APP_PATH" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"

[[ -f "$STAGING/$APP_NAME/Contents/Info.plist" && -L "$STAGING/Applications" ]] || {
    printf 'staging 内容不对：%s\n' "$STAGING" >&2
    exit 1
}

# 覆盖前先删，hdiutil 不会为一个已存在的输出文件停下来问人。
if [[ -e "$DMG_PATH" ]]; then
    printf '  覆盖已存在的 %s\n' "$DMG_NAME"
    rm -f "$DMG_PATH"
fi

printf '创建 DMG…\n'
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH"

[[ -f "$DMG_PATH" ]] || {
    printf 'hdiutil 没有产出 %s\n' "$DMG_PATH" >&2
    exit 1
}

printf '→ %s（%s）\n' "$DMG_PATH" "$(du -h "$DMG_PATH" | cut -f1)"
