#!/usr/bin/env python3
"""把已构建的轻醒装到 /Applications，并在桌面放好快捷按钮。

和 build_local.py 分工：那个只构建和签名（"without installing or launching"），
这个只安装和放按钮。可以重复跑——同名按钮会被更新，不会堆出好几份。

3.0 起轻醒只有**一个** app。以前是四个（关闭屏幕 / 开启屏幕 / 轻醒按键 / 轻醒设置），
同一个可执行文件换 plist 出来的；那三个"屏幕动作"本来就是同一个反转的两端
（见 ScreenButtonState.action），所以双击「轻醒」就是切换，设置收进常驻的菜单栏图标。

替换下来的旧版一律挪进 ~/Documents/ProjectArchive/service-backups/<日期>-轻醒装机/，
不删。3.0 之前的四个 app 和四个桌面按钮也一并归档 —— 它们还留在原地只会让人点错。

桌面按钮：
    轻醒 → 轻醒.app

关屏模式持有 PreventUserIdleSystemSleep 电源声明，只在用户手动停（再双击一次
「轻醒」、菜单栏退出、或按键规则取消）或应用退出时释放。**合盖不会让它放手**，
机器停在浅睡状态（DarkWake）里反复醒来，任务继续跑——所以合盖也不等于"收工了"。
这是有意保留的行为（详见 docs/architecture.md），按钮的 Finder 注释里也写了。

本脚本不构建，只安装。先构建：
    python3 scripts/build.py
若它报 "You have not agreed to the Xcode license"，先在终端里跑一次
    sudo xcodebuild -license accept
（Xcode 跨大版本升级会让许可证同意失效，之后 /usr/bin 下的 swiftc / xcrun / lipo
这些 shim 一律报这个错。）
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import plistlib
import shutil
import subprocess
import sys
from collections.abc import Iterable
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "apps/screen-guard/build"
ARCHIVE = Path.home() / "Documents/ProjectArchive/service-backups"
COMMENT_KEY = "com.apple.metadata:kMDItemFinderComment"

# (桌面按钮名, /Applications 里的 app 名, 按钮注释)
SHORTCUTS = [
    (
        "轻醒",
        "轻醒.app",
        "双击切换熄屏模式：关屏 ↔ 正常使用。菜单栏的显示器图标里有「轻醒设置…」"
        "和「退出轻醒」。关屏模式持有防闲置睡眠声明，合盖也不会放手——要停就再双击一次。",
    ),
]

# 3.0 之前的四个 app 和四个桌面按钮。合并成单 app 之后它们只剩误导作用，
# 装机时一并归档（挪进备份目录，不删）。
RETIRED_APPS = ["关闭屏幕.app", "开启屏幕.app", "轻醒按键.app", "轻醒设置.app"]
RETIRED_SHORTCUTS = ["关闭屏幕（合盖不休）", "开启屏幕", "轻醒设置", "轻醒按键"]


class InstallError(SystemExit):
    """装机失败。用 SystemExit 的子类，报错时只留一句话，不吐 traceback。"""


def run(*arguments: str | Path, **kwargs) -> subprocess.CompletedProcess:
    command = [str(argument) for argument in arguments]
    # 注释是二进制 plist 的十六进制，整串打出来能刷满一屏
    shown = [c if len(c) <= 64 else c[:61] + "…" for c in command]
    print("  " + " ".join(shown), flush=True)
    return subprocess.run(command, check=True, **kwargs)


def make_alias(target: Path, link: Path) -> None:
    """建一个真正的 Finder 别名（不是符号链接）。

    Finder 自动化（osascript 控制 Finder）需要 TCC 授权，在无人值守时会报
    -10004 权限违例；这里改用 JXA 的 ObjC bridge 直接调 Foundation 的
    bookmark API，只碰文件系统，不碰 Finder。
    """
    if link.exists() or link.is_symlink():
        link.unlink()
    script = f"""
ObjC.import("Foundation");
var err = $();
var src = $.NSURL.fileURLWithPath({json.dumps(str(target))});
var data = src.bookmarkDataWithOptionsIncludingResourceValuesForKeysRelativeToURLError(
    $.NSURLBookmarkCreationSuitableForBookmarkFile, $(), $(), err);
if (data.isNil()) throw new Error("生成书签失败：" + err.localizedDescription.js);
var dst = $.NSURL.fileURLWithPath({json.dumps(str(link))});
if (!$.NSURL.writeBookmarkDataToURLOptionsError(data, dst, 0, err)) {{
    throw new Error("写别名失败：" + err.localizedDescription.js);
}}
"ok";
"""
    subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
        check=True, capture_output=True, text=True,
    )


def alias_target(link: Path) -> Path | None:
    """读一个别名指向哪里；不是别名、或指向的东西已经没了，都返回 None。

    桌面按钮换过安装目录、或 app 被挪走时，靠这个发现"按钮还在，但指错了"。
    """
    script = f"""
ObjC.import("Foundation");
var stale = $();
var resolved = $.NSURL.URLByResolvingAliasFileAtURLOptionsError(
    $.NSURL.fileURLWithPath({json.dumps(str(link))}), 0, stale);
resolved.isNil() ? "" : resolved.path.js;
"""
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    resolved = result.stdout.strip()
    # 普通文件也会解析成它自己——那不算别名，返回 None 让调用方重建
    if not resolved or resolved == str(link):
        return None
    return Path(resolved)


def set_comment(path: Path, text: str) -> None:
    """写 Finder 注释（显示简介里的"注释"栏）。值必须是二进制 plist。"""
    value = plistlib.dumps(text, fmt=plistlib.FMT_BINARY)
    run("/usr/bin/xattr", "-wx", COMMENT_KEY, value.hex(), path)
    # 让 Spotlight 元数据立刻刷新，Finder 才读得到
    subprocess.run(["/usr/bin/mdimport", "-i", str(path)], capture_output=True)


def read_version(app: Path) -> str:
    """读 Info.plist 里的版本号，只用于打印。"""
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException):
        return "(版本读不出来)"
    return f"{info.get('CFBundleShortVersionString', '?')} (build {info.get('CFBundleVersion', '?')})"


def check_build_output() -> None:
    """构建产物齐全才动手。装到一半才发现产物缺了，旧版已经挪走了。"""
    problems = []
    for _, name, _ in SHORTCUTS:
        app = BUILD / name
        if not app.is_dir():
            problems.append(f"缺 {app}")
            continue
        for required in ("Contents/Info.plist", "Contents/MacOS/ScreenGuard"):
            if not (app / required).exists():
                problems.append(f"{app} 里缺 {required}")
    if problems:
        raise InstallError(
            "构建产物不齐，先构建：\n    python3 scripts/build.py\n"
            + "\n".join(f"  - {problem}" for problem in problems)
            + '\n若构建报 "You have not agreed to the Xcode license"，'
            "先在终端里跑一次 sudo xcodebuild -license accept。"
        )


def archive_existing(item: Path) -> Path | None:
    """替换前把已经在位的那份挪进归档目录，不删。

    `item` 可能是 app 目录，也可能是桌面上一个按钮（别名文件）。
    """
    if not item.exists() and not item.is_symlink():
        return None
    folder = ARCHIVE / f"{dt.date.today().isoformat()}-轻醒装机"
    folder.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%H%M%S")
    destination = folder / f"{item.name}-{stamp}"
    # 同一秒里连装两次时别把上一份归档盖掉——那是备份，静默删除最不该发生
    counter = 2
    while destination.exists():
        destination = folder / f"{item.name}-{stamp}-{counter}"
        counter += 1
    shutil.move(item, destination)
    print(f"  旧版已归档：{destination}")
    return destination


def retire_legacy(paths: Iterable[Path]) -> None:
    """把 3.0 之前的旧产物挪进归档。找不到就当已经清过了。"""
    present = [path for path in paths if path.exists() or path.is_symlink()]
    if not present:
        return
    print("归档 3.0 之前的旧产物：")
    for path in present:
        archive_existing(path)


def install_apps(applications: Path) -> list[tuple[Path, str]]:
    """装 app：先把旧的归档，铺上新的，再验签名；任何一步失败就退回原状。

    今天 `SHORTCUTS` 里只有一个 app，所以这就是一次普通的"换上去、换不成就换回来"。
    仍然按列表走，是因为"装哪些、装到哪"只由 `SHORTCUTS` 一处说了算——
    以后真再加一个 app，这里不用改。半装状态（新的铺了一半、旧的已经挪走）
    比"完全没装"更难查，所以宁可整批退回。
    """
    check_build_output()
    applications.mkdir(parents=True, exist_ok=True)

    steps = [
        {
            "source": BUILD / name,
            "destination": applications / name,
            "version": read_version(BUILD / name),
            "archived": None,   # 旧版挪到哪儿了
            "replaced": False,  # 新的铺上去了没
        }
        for _, name, _ in SHORTCUTS
    ]

    try:
        failed = "?"
        for step in steps:
            failed = step["destination"].name
            print(f"安装 {failed}  {step['version']}")
            step["archived"] = archive_existing(step["destination"])
            run("/usr/bin/ditto", step["source"], step["destination"])
            step["replaced"] = True
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", step["destination"])
    except subprocess.CalledProcessError as error:
        tool = Path(str(error.cmd[0])).name
        print(f"\n{tool} 退出码 {error.returncode}，退回原状：")
        for step in reversed(steps):
            destination = step["destination"]
            if step["archived"] is not None:
                # 先把半装的新目录清掉，再把旧版挪回原位 —— dst 已存在时
                # shutil.move 会把它塞进那个目录里，变成 destination/xxx.app
                shutil.rmtree(destination, ignore_errors=True)
                shutil.move(step["archived"], destination)
                print(f"  退回原版：{destination.name}")
            elif step["replaced"]:
                shutil.rmtree(destination, ignore_errors=True)
                print(f"  清空（原来没装过）：{destination.name}")
        raise InstallError(
            f"{failed} 安装失败：{tool} 退出码 {error.returncode}。已退回原状。"
        ) from error

    return [(step["destination"], step["version"]) for step in steps]


def place_shortcuts(applications: Path, desktop: Path, force: bool) -> None:
    for label, name, comment in SHORTCUTS:
        target = applications / name
        if not target.is_dir():
            raise InstallError(f"找不到 {target}，先装应用（去掉 --shortcuts-only）")
        link = desktop / label
        if link.exists() and not force:
            # 重建别名会打乱 Finder 记住的图标位置，所以默认只在缺的时候建。
            # 但"按钮还在、却指错了地方"是另一回事——那种必须重建，否则点了没反应。
            current = alias_target(link)
            if current is not None and os.path.realpath(current) == os.path.realpath(target):
                set_comment(link, comment)  # 注释是幂等的，每次都可以刷
                print(f"桌面按钮已在位，只更新注释：{label}")
                continue
            print(f"桌面按钮指向不对（{current}），重建：{label}")
        make_alias(target, link)
        set_comment(link, comment)
        print(f"桌面按钮：{label} → {target}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--applications", type=Path, default=Path("/Applications"))
    parser.add_argument("--desktop", type=Path, default=Path.home() / "Desktop")
    parser.add_argument(
        "--shortcuts-only", action="store_true",
        help="只重建桌面快捷按钮，不碰 /Applications（应用已经在位时用这个）",
    )
    parser.add_argument(
        "--force-shortcuts", action="store_true",
        help="连已在位的按钮也重建（默认保留，免得图标跳位）",
    )
    options = parser.parse_args()

    if sys.platform != "darwin":
        raise InstallError("轻醒只在 macOS 上安装。")
    if not options.desktop.is_dir():
        raise InstallError(f"桌面目录不存在：{options.desktop}")

    if not options.shortcuts_only:
        print("== 装到 " + str(options.applications) + " ==")
        installed = install_apps(options.applications)
        print(f"  装好 {len(installed)} 个应用")
        retire_legacy(options.applications / name for name in RETIRED_APPS)

    print("== 桌面快捷按钮 ==")
    place_shortcuts(options.applications, options.desktop, options.force_shortcuts)
    retire_legacy(options.desktop / label for label in RETIRED_SHORTCUTS)
    print("\n完成。关屏模式「合盖不休」的含义见 docs/architecture.md。")


if __name__ == "__main__":
    main()
