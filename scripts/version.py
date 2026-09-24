#!/usr/bin/env python3
"""TokenMeter 版本单一来源：以仓库根目录的 VERSION 为准，同步 Xcode 工程里的版本号。

VERSION 只有一行 `major.minor.patch`（例如 `0.2.0`），结尾换行；预发布可以带后缀
（`0.3.0-beta.1`），后缀原样进入 MARKETING_VERSION。发版时先写好 CHANGELOG.md 条目、
把 VERSION 改成新版本，跑一次本脚本让工程跟上，然后提交并打 `v<version>` 标签；发布由
标签触发的 GitHub Actions 完成，工程里不再有第二个版本来源。完整流程见 docs/releasing.md。

用法：
    python3 scripts/version.py
        把 VERSION 写进 TokenMeter.xcodeproj/project.pbxproj，只动应用目标 Debug 与
        Release 这两个 build configuration 的两个设置：
          - MARKETING_VERSION 改成 VERSION 的内容（0.2.0、0.3.0-beta.1）；
          - CURRENT_PROJECT_VERSION 改成数字部分的 major*10000 + minor*100 + patch
            （0.2.0 → 200，0.3.0-beta.1 → 300），整数，供 Xcode 与系统读取。
        幂等：已经一致时不写文件，重复执行不会产生新的改动。

    python3 scripts/version.py --check
        只读校验，不改文件：
          - pbxproj 里 Debug / Release 的上述两个值都与 VERSION 一致；
          - TokenMeter/Info.plist 仍用 $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION)
            引用构建设置，而不是写死版本号。
        不一致时逐条打印人能看懂的差异并以退出码 1 结束，成功退出 0，供 CI 与发布流程卡门。

    python3 scripts/version.py -h
        打印本说明。

脚本只在本地读写文件，不做任何 git 操作（不 add、不 commit、不打 tag）。
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
PBXPROJ = ROOT / "TokenMeter.xcodeproj" / "project.pbxproj"
INFO_PLIST = ROOT / "TokenMeter" / "Info.plist"

SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.\-]+)?$")
CONFIGURATION = re.compile(r"\{isa = XCBuildConfiguration;.*?name = (Debug|Release); \};", re.DOTALL)
MARKETING = re.compile(r"MARKETING_VERSION = ([^;]*);")
BUILD = re.compile(r"CURRENT_PROJECT_VERSION = ([^;]*);")

PLIST_REFERENCES = (
    ("CFBundleShortVersionString", "$(MARKETING_VERSION)"),
    ("CFBundleVersion", "$(CURRENT_PROJECT_VERSION)"),
)


def relative(path: Path) -> str:
    return str(path.relative_to(ROOT))


def fail(message: str, *hints: str) -> NoReturn:
    print(f"错误：{message}", file=sys.stderr)
    for hint in hints:
        print(f"      {hint}", file=sys.stderr)
    raise SystemExit(1)


def read_text(path: Path) -> str:
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            return handle.read()
    except FileNotFoundError:
        fail(f"找不到 {relative(path)}。")
    except UnicodeDecodeError:
        fail(f"{relative(path)} 不是 UTF-8 文本，无法安全改写。")


def write_text(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def load_version() -> str:
    """读出 VERSION 里的版本号，并确认它可以被推导成构建号。"""
    version = read_text(VERSION_FILE).strip()
    if not SEMVER.match(version):
        fail(
            f"{relative(VERSION_FILE)} 的内容是 {version!r}，不是 major.minor.patch 形式。",
            "例如：0.2.0，预发布写成 0.3.0-beta.1",
        )
    return version


def build_number(version: str) -> int:
    """由版本号推导 CURRENT_PROJECT_VERSION：major*10000 + minor*100 + patch。"""
    major, minor, patch = SEMVER.match(version).groups()
    return int(major) * 10000 + int(minor) * 100 + int(patch)


def load_configurations(text: str) -> dict[str, str]:
    """取出携带 MARKETING_VERSION 的构建配置正文，键为 Debug / Release。"""
    found = [
        (match.group(1), match.group(0))
        for match in CONFIGURATION.finditer(text)
        if "MARKETING_VERSION" in match.group(0)
    ]
    names = sorted(name for name, _ in found)
    if names != ["Debug", "Release"]:
        listed = "、".join(name for name, _ in found) if found else "一个都没有"
        fail(
            f"{relative(PBXPROJ)} 里带 MARKETING_VERSION 的构建配置是 {listed}，期望 Debug 与 Release 各一个。",
            "本脚本只同步这两个配置，不做猜测；请在 Xcode 里确认工程结构后重试。",
        )
    return dict(found)


def synchronize(text: str, version: str, number: int) -> tuple[str, list[str]]:
    """把带 MARKETING_VERSION 的配置改成目标值，返回新文本与改动说明。"""
    changes: list[str] = []

    def rewrite(match: re.Match[str]) -> str:
        block = match.group(0)
        if "MARKETING_VERSION" not in block:
            return block

        name = match.group(1)
        current_marketing = MARKETING.search(block).group(1)
        current_build = BUILD.search(block)

        updated = MARKETING.sub(f"MARKETING_VERSION = {version};", block, count=1)
        if current_build:
            updated = BUILD.sub(f"CURRENT_PROJECT_VERSION = {number};", updated, count=1)
        else:
            updated = updated.replace(
                f"MARKETING_VERSION = {version};",
                f"MARKETING_VERSION = {version}; CURRENT_PROJECT_VERSION = {number};",
                1,
            )

        if current_marketing != version:
            changes.append(f"  {name}: MARKETING_VERSION {current_marketing} → {version}")
        if current_build is None:
            changes.append(f"  {name}: CURRENT_PROJECT_VERSION（缺失）→ {number}")
        elif current_build.group(1) != str(number):
            changes.append(f"  {name}: CURRENT_PROJECT_VERSION {current_build.group(1)} → {number}")
        return updated

    return CONFIGURATION.sub(rewrite, text), changes


def synchronize_command() -> int:
    version = load_version()
    number = build_number(version)

    text = read_text(PBXPROJ)
    load_configurations(text)
    updated, changes = synchronize(text, version, number)

    if not changes:
        print(f"工程已与 VERSION 一致：MARKETING_VERSION = {version}，CURRENT_PROJECT_VERSION = {number}，未改动文件。")
        return 0

    write_text(PBXPROJ, updated)
    print(f"已按 VERSION（{version}，构建号 {number}）更新 {relative(PBXPROJ)}：")
    print("\n".join(changes))
    return 0


def mismatch(label: str, expected: object, actual: object) -> str:
    return f"    {label:<26} 期望 {expected}，实际 {actual}"


def check_command() -> int:
    version = load_version()
    number = build_number(version)
    problems: list[str] = []

    text = read_text(PBXPROJ)
    for name, block in sorted(load_configurations(text).items()):
        lines: list[str] = []
        actual_marketing = MARKETING.search(block).group(1)
        if actual_marketing != version:
            lines.append(mismatch("MARKETING_VERSION", version, actual_marketing))
        build = BUILD.search(block)
        actual_build = build.group(1) if build else "（缺失）"
        if actual_build != str(number):
            lines.append(mismatch("CURRENT_PROJECT_VERSION", number, actual_build))
        if lines:
            problems.append(f"{relative(PBXPROJ)} · {name}\n" + "\n".join(lines))

    try:
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)
    except FileNotFoundError:
        fail(f"找不到 {relative(INFO_PLIST)}。")
    except plistlib.InvalidFileException:
        fail(f"{relative(INFO_PLIST)} 不是可解析的 plist。")

    lines = []
    for key, expected in PLIST_REFERENCES:
        actual = info.get(key)
        if actual != expected:
            lines.append(mismatch(key, expected, repr(actual)))
    if lines:
        problems.append(f"{relative(INFO_PLIST)}\n" + "\n".join(lines))

    if problems:
        print(
            f"版本不一致：VERSION 是 {version}（CURRENT_PROJECT_VERSION 应为 {number}），但工程不是。\n",
            file=sys.stderr,
        )
        for problem in problems:
            print(problem, file=sys.stderr)
        print("\n让工程跟上 VERSION：python3 scripts/version.py", file=sys.stderr)
        return 1

    print(f"版本一致：{version}（CURRENT_PROJECT_VERSION {number}），Info.plist 仍由构建设置注入。")
    return 0


def main(argv: list[str]) -> int:
    arguments = argv[1:]
    if not arguments:
        return synchronize_command()
    if arguments == ["--check"]:
        return check_command()
    if arguments in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0

    print(f"未知参数：{' '.join(arguments)}", file=sys.stderr)
    print("用法：python3 scripts/version.py [--check]（-h 查看完整说明）", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
