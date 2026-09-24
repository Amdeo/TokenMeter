#!/usr/bin/env python3
"""把一次发布写进 appcast.xml —— Sparkle 读取的更新源。

Sparkle 只安装由 Info.plist 里那把公钥（SUPublicEDKey）对应的私钥签过名的压缩包，
所以这里写下的签名就是「没有 Developer ID 也能安全自更新」的全部依据。私钥不进仓库：
CI 把它放在 SPARKLE_PRIVATE_KEY 里经 stdin 交给 Sparkle 的 sign_update，本机则用
--private-key 指向仓库外的密钥文件。

用法：
    python3 scripts/appcast.py <version> <zip 路径> <下载 URL>
        [--private-key <私钥文件>] [--sign-update <sign_update 路径>]

    <version>    要写进 feed 的版本号，必须与 CHANGELOG.md 里 `## <version>` 条目一致；
                 条目正文（到下一个 `## ` 之前）会转成 HTML 放进 <description>。
                 feed 里的 `sparkle:version` 写的**不是**这个版本号，而是由它推出的
                 构建号（major*10000 + minor*100 + patch，0.4.0 → 400）——Sparkle
                 拿它跟应用自己的 `CFBundleVersion`（`scripts/version.py` 写的同一个数）
                 比大小，写错就等于永远没有更新。
    <zip 路径>   要签名的压缩包，通常来自 CI 的打包步骤。
    <下载 URL>   这个压缩包对外的下载地址，写进 <enclosure url="…">。

    私钥来源二选一：环境变量 SPARKLE_PRIVATE_KEY（经 stdin，`--ed-key-file -`），
    或 --private-key <文件>；两者都没有时交给 sign_update 自己从钥匙串里找。

    sign_update 的位置按顺序解析：--sign-update 参数、SIGN_UPDATE 环境变量、最后在
    Xcode DerivedData 与仓库 build/ 下的 SourcePackages/artifacts/*/Sparkle/bin/
    里找最新的一份。

幂等：feed 里已经有同版本时什么都不做，直接成功返回（CI 重跑不会插出两条）。
本脚本只改 appcast.xml，不做任何 git 操作（不 add、不 commit、不打 tag）。
"""

from __future__ import annotations

import email.utils
import glob
import html
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
FEED = ROOT / "appcast.xml"
CHANGELOG = ROOT / "CHANGELOG.md"

REPOSITORY = "https://github.com/Amdeo/TokenMeter"
MINIMUM_SYSTEM_VERSION = "14.0"

# `appcast.xml` 不存在时用它开局；正常情况下仓库里就有这份骨架，两边保持一致。
SKELETON = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>TokenMeter</title>
        <link>https://raw.githubusercontent.com/Amdeo/TokenMeter/main/appcast.xml</link>
        <description>Updates for TokenMeter.</description>
        <language>en</language>
    </channel>
</rss>
"""

# 新条目插在这个锚点之后：里面是「最新在最前」。
ANCHOR = "        <language>en</language>\n"

# sign_update 是 Sparkle 的官方命令行工具，随 SPM 依赖被 Xcode 下载到 DerivedData；
# 本机开发时也可能只存在于仓库自己的 build/ 派生数据目录里。Xcode 给这份 artifact 起的
# 目录名跟着包标识走（实测是 `artifacts/sparkle/Sparkle/bin/`），所以中间那段用通配，
# 免得换个 Xcode 版本就找不到工具。
SIGN_UPDATE_PATTERNS = (
    str(Path.home())
    + "/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/*/Sparkle/bin/sign_update",
    str(ROOT / "build/*/SourcePackages/artifacts/*/Sparkle/bin/sign_update"),
    str(ROOT / ".build/artifacts/*/Sparkle/bin/sign_update"),
)

# 更新窗口的排版。**只有间距，没有颜色和字体**：Sparkle 自己会注入一份样式表，深色
# 模式下的文字颜色由它决定，feed 再带一套配色就是在跟自己打架。间距它不管，所以补上。
STYLE = """<style>
  h2 { font-size: 1.05em; margin: 0 0 .5em; }
  ul { margin: 0; padding-left: 1.2em; }
  li { margin: .3em 0; }
  p { margin: .8em 0 0; }
</style>"""


def fail(message: str, *hints: str) -> NoReturn:
    print(f"错误：{message}", file=sys.stderr)
    for hint in hints:
        print(f"      {hint}", file=sys.stderr)
    raise SystemExit(1)


def relative(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def escape(text: str) -> str:
    """XML 文本与属性值里要转义的那几个字符。"""
    return html.escape(text, quote=True)


# ---------------------------------------------------------------------------
# CHANGELOG.md
# ---------------------------------------------------------------------------


def changelog_entry(version: str) -> str:
    """取出 `## <version> — <日期>` 到下一个 `## ` 之间的正文。

    标题行上版本号后面还跟着日期，所以取到行尾为止；版本号后面不允许直接接别的
    版本字符，免得找 `0.3.0` 时命中 `## 0.3.0-beta.1`。
    """
    try:
        text = CHANGELOG.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"找不到 {relative(CHANGELOG)}。")

    pattern = rf"^## {re.escape(version)}(?![0-9A-Za-z.\-])[^\n]*\n(.*?)(?=^## |\Z)"
    match = re.search(pattern, text, re.M | re.S)
    body = match.group(1).strip() if match else ""
    if not body:
        fail(
            f"{relative(CHANGELOG)} 里没有 {version} 的条目。",
            f"先写 `## {version} — <日期>` 一节（中英双语），再发版。",
        )
    return body


def as_html(markdown: str) -> str:
    """CHANGELOG 用到的那点 markdown 转成 HTML：列表、粗体、行内代码、链接。

    只支持这四种是刻意的——文件是我们自己写的，语法小到能一眼看懂、不会在发版当天
    因为一个通用解析器而失败。先整体转义再逐个还原标记，所以正文里出现的 `<` 是文字
    而不是标签。
    """
    blocks: list[str] = []
    for raw in markdown.splitlines():
        line = raw.strip()
        if not line:
            continue

        # 只吃掉行首的列表符号，不能用 `lstrip("-* ")`：那会连 `**粗体**` 开头的
        # 星号一起吃掉。
        escaped = html.escape(re.sub(r"^[-*]\s+", "", line))

        # 链接先处理，地址暂存起来：下面每个替换都作用于整行，谁后跑谁就可能改到前一个
        # 结果里生成的 href（URL 里带 `**` 就会被写成畸形的 <a>）。畸形的链接不是安全
        # 问题（引号早已变成实体），但确实不对，而且链接文字自己还要再格式化。
        addresses: list[str] = []

        def park(match: re.Match[str]) -> str:
            addresses.append(match.group(2))
            return f'<a href="\x00{len(addresses) - 1}\x00">{match.group(1)}</a>'

        escaped = re.sub(r"\[(.+?)\]\((https?://[^)\s]+)\)", park, escaped)
        escaped = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)
        escaped = re.sub(r"`(.+?)`", r"<code>\1</code>", escaped)
        escaped = re.sub(r"\x00(\d+)\x00", lambda m: addresses[int(m.group(1))], escaped)

        bullet = line.startswith(("- ", "* "))
        blocks.append(f"<li>{escaped}</li>" if bullet else f"<p>{escaped}</p>")

    # 连续的列表项合成一个 <ul>，而不是每条一个。
    parts: list[str] = []
    inside_list = False
    for block in blocks:
        if block.startswith("<li>") and not inside_list:
            parts.append("<ul>")
            inside_list = True
        elif not block.startswith("<li>") and inside_list:
            parts.append("</ul>")
            inside_list = False
        parts.append(block)
    if inside_list:
        parts.append("</ul>")

    return "".join(parts)


def description(version: str) -> str:
    """Sparkle 更新窗口里显示的发行说明，**随 feed 一起下发**。

    不用 `sparkle:releaseNotesLink`：那不是给用户点的链接，而是 Sparkle 会加载进更新
    窗口的一整个页面——于是 GitHub 的发行页面连同导航条被塞进一个小面板里，断网时什
    么也看不到。
    """
    listing = as_html(changelog_entry(version))
    link = f'<p><a href="{REPOSITORY}/releases/tag/v{version}">Release notes on GitHub</a></p>'
    inner = f"{STYLE}<h2>TokenMeter {escape(version)}</h2>{listing}{link}"

    # CDATA 段里不能出现它自己的结束标记。正文里本该不会有，但用户写的字要防一手。
    return inner.replace("]]>", "]]&gt;")


# ---------------------------------------------------------------------------
# 签名
# ---------------------------------------------------------------------------


def find_sign_update(explicit: str | None) -> Path:
    """按参数 / 环境变量 / DerivedData 的顺序找 sign_update。"""
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_file():
            fail(f"--sign-update 指向的 {path} 不是文件。")
        return path

    from_environment = os.environ.get("SIGN_UPDATE", "").strip()
    if from_environment:
        path = Path(from_environment).expanduser()
        if not path.is_file():
            fail(f"SIGN_UPDATE 指向的 {path} 不是文件。")
        return path

    found = [Path(match) for pattern in SIGN_UPDATE_PATTERNS for match in glob.glob(pattern)]
    if not found:
        fail(
            "找不到 Sparkle 的 sign_update。",
            "先在 Xcode 里解析一次 Sparkle 依赖（或用 --sign-update / SIGN_UPDATE 指定路径）。",
        )
    return max(found, key=lambda path: path.stat().st_mtime)


def sign(archive: Path, sign_update: Path, private_key: str | None) -> tuple[str, str]:
    """用 Sparkle 自己的工具签名，返回 (sparkle:edSignature, length)。"""
    secret = os.environ.get("SPARKLE_PRIVATE_KEY", "").strip()

    command = [str(sign_update)]
    stdin: str | None = None
    if private_key:
        command += ["--ed-key-file", str(Path(private_key).expanduser())]
    elif secret:
        # 走 stdin，不用已经废弃的 `-s`：那个参数明确拒绝新生成的密钥，也就是今天所有
        # 人手里的密钥；而且它的报错只在 stderr 没被吞掉时才看得见。
        command += ["--ed-key-file", "-"]
        stdin = secret + "\n"
    command.append(str(archive))

    result = subprocess.run(command, input=stdin, capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr.strip() or result.stdout.strip() or "（没有输出）")
        fail(f"sign_update 失败（退出码 {result.returncode}）：", detail)

    # 它打印的是两个可直接粘贴的属性：
    #   sparkle:edSignature="…" length="…"
    signature = re.search(r'sparkle:edSignature="([^"]+)"', result.stdout)
    length = re.search(r'length="(\d+)"', result.stdout)
    if not signature or not length:
        fail("sign_update 的输出看不懂：", result.stdout.strip())

    actual = archive.stat().st_size
    if int(length.group(1)) != actual:
        fail(
            f"sign_update 报的长度 {length.group(1)} 与 {relative(archive)} 的实际大小 {actual} 不符。",
            "说明签名的不是将要发布的那个文件。",
        )
    return signature.group(1), length.group(1)


# ---------------------------------------------------------------------------
# feed
# ---------------------------------------------------------------------------


VERSION_PATTERN = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.\-]+)?$")


def build_number(version: str) -> int:
    """由版本号推出构建号。公式与 `scripts/version.py` 必须一致。

    Sparkle 比较的是 feed 里的 `sparkle:version` 与应用 Info.plist 里的
    `CFBundleVersion`（由 `CURRENT_PROJECT_VERSION` 注入），两边都是这个数，
    所以改公式要两边一起改，否则更新会静默地永远不触发。
    """
    match = VERSION_PATTERN.match(version)
    if not match:
        fail(f"版本号 {version!r} 不是 major.minor.patch 形式（预发布可带后缀，如 0.4.0-beta.1）。")
    major, minor, patch = match.groups()
    return int(major) * 10000 + int(minor) * 100 + int(patch)


def item(version: str, notes: str, url: str, signature: str, length: str) -> str:
    return f"""        <item>
            <title>{escape(version)}</title>
            <pubDate>{email.utils.formatdate(localtime=False, usegmt=False)}</pubDate>
            <sparkle:version>{build_number(version)}</sparkle:version>
            <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
            <link>{escape(f"{REPOSITORY}/releases/tag/v{version}")}</link>
            <description><![CDATA[{notes}]]></description>
            <enclosure url="{escape(url)}"
                       length="{length}"
                       type="application/octet-stream"
                       sparkle:edSignature="{signature}" />
        </item>
"""


def main(argv: list[str]) -> int:
    arguments = argv[1:]
    if arguments in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0

    positional: list[str] = []
    private_key: str | None = None
    sign_update_path: str | None = None

    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--private-key":
            index += 1
            if index >= len(arguments):
                fail("--private-key 后面要跟一个密钥文件路径。")
            private_key = arguments[index]
        elif argument == "--sign-update":
            index += 1
            if index >= len(arguments):
                fail("--sign-update 后面要跟一个路径。")
            sign_update_path = arguments[index]
        elif argument.startswith("-"):
            fail(f"未知参数：{argument}", "用法：python3 scripts/appcast.py <version> <zip> <url>（-h 查看完整说明）")
        else:
            positional.append(argument)
        index += 1

    if len(positional) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    version, archive_name, url = positional
    archive = Path(archive_name)
    if not archive.is_file():
        fail(f"找不到要签名的压缩包：{archive_name}")

    feed = FEED.read_text(encoding="utf-8") if FEED.exists() else SKELETON

    # 幂等放在签名之前：重复执行不必再碰一次私钥，CI 重跑也不会因为密钥缺失而失败。
    if f"<sparkle:version>{build_number(version)}</sparkle:version>" in feed:
        print(f"appcast.xml 里已经有 {version} —— 不动它。")
        return 0

    if ANCHOR not in feed:
        fail(
            f"{relative(FEED)} 的结构不符合预期（找不到 <language>en</language>）。",
            "这个脚本只认仓库里的那份骨架，结构变了就手工处理。",
        )

    # 先备好说明再签名：CHANGELOG 缺条目这种事要在碰私钥之前就失败。
    notes = description(version)
    signature, length = sign(archive, find_sign_update(sign_update_path), private_key)
    FEED.write_text(feed.replace(ANCHOR, ANCHOR + item(version, notes, url, signature, length), 1), encoding="utf-8")
    print(f"appcast.xml 现在提供 {version}（{length} 字节）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
