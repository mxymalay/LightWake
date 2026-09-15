#!/usr/bin/env python3
"""把已构建的轻醒应用装到 /Applications，并在桌面放好快捷按钮。

和 build_local.py 分工：那个只构建和签名（"without installing or launching"），
这个只安装和放按钮。可以重复跑——同名按钮会被更新，不会堆出好几份。

桌面按钮：
    关闭屏幕（合盖不休） → 关闭屏幕.app
    开启屏幕             → 开启屏幕.app
    轻醒设置             → 轻醒设置.app
    轻醒按键             → 轻醒按键.app

"合盖不休"是提醒：轻醒关屏模式持有 PreventUserIdleSystemSleep 电源声明，只在用户
手动停（双击「开启屏幕」）或应用退出时释放。合盖不会让它放手，机器停在浅睡状态
（DarkWake）里反复醒来，任务继续跑——所以合盖也不等于"收工了"。
这是有意保留的行为（详见 docs/architecture.md），写在按钮上让人一眼看到。
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "apps/screen-guard/build"
ARCHIVE = Path.home() / "Documents/ProjectArchive/service-backups"
COMMENT_KEY = "com.apple.metadata:kMDItemFinderComment"

# (桌面按钮名, /Applications 里的 app 名, 按钮注释)
SHORTCUTS = [
    (
        "关闭屏幕（合盖不休）",
        "关闭屏幕.app",
        "双击进入关屏模式：屏幕关掉、任务继续跑。合盖也不会真正休眠，"
        "要双击桌面上的「开启屏幕」才能停。",
    ),
    ("开启屏幕", "开启屏幕.app", "双击退出关屏模式，恢复正常使用。"),
    ("轻醒设置", "轻醒设置.app", "配置按键规则、查看关屏与亮屏说明。"),
    ("轻醒按键", "轻醒按键.app", "供键盘、鼠标和外部映射工具调用，执行指定按键的屏幕规则。"),
]


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


def set_comment(path: Path, text: str) -> None:
    """写 Finder 注释（显示简介里的"注释"栏）。值必须是二进制 plist。"""
    value = plistlib.dumps(text, fmt=plistlib.FMT_BINARY)
    run("/usr/bin/xattr", "-wx", COMMENT_KEY, value.hex(), path)
    # 让 Spotlight 元数据立刻刷新，Finder 才读得到
    subprocess.run(["/usr/bin/mdimport", "-i", str(path)], capture_output=True)


def read_version(app: Path) -> str:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    return f"{info.get('CFBundleShortVersionString', '?')} (build {info.get('CFBundleVersion', '?')})"


def archive_existing(app: Path) -> Path | None:
    """替换前把已装的那份挪进归档目录，不删。"""
    if not app.exists():
        return None
    stamp = dt.datetime.now().strftime("%H%M%S")
    folder = ARCHIVE / f"{dt.date.today().isoformat()}-轻醒装机"
    folder.mkdir(parents=True, exist_ok=True)
    destination = folder / f"{app.name}-{stamp}"
    shutil.rmtree(destination, ignore_errors=True)
    app.rename(destination)
    print(f"  旧版已归档：{destination}")
    return destination


def install_apps(applications: Path) -> list[tuple[Path, str]]:
    missing = [name for _, name, _ in SHORTCUTS if not (BUILD / name).is_dir()]
    if missing:
        raise SystemExit(
            "构建产物不齐，先跑 scripts/build.py：\n  "
            + "\n  ".join(str(BUILD / name) for name in missing)
        )

    installed = []
    for _, name, _ in SHORTCUTS:
        source = BUILD / name
        destination = applications / name
        version = read_version(source)
        print(f"安装 {name}  {version}")
        archive_existing(destination)
        run("/usr/bin/ditto", source, destination)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", destination)
        installed.append((destination, version))
    return installed


def place_shortcuts(applications: Path, desktop: Path, force: bool) -> None:
    for label, name, comment in SHORTCUTS:
        target = applications / name
        if not target.is_dir():
            raise SystemExit(f"找不到 {target}，先装应用（去掉 --shortcuts-only）")
        link = desktop / label
        if link.exists() and not force:
            # 重建别名会打乱 Finder 记住的图标位置，所以默认只在缺的时候建。
            # 注释是幂等的，每次都可以刷。
            set_comment(link, comment)
            print(f"桌面按钮已在位，只更新注释：{label}")
        else:
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
        raise SystemExit("轻醒只在 macOS 上安装。")
    if not options.desktop.is_dir():
        raise SystemExit(f"桌面目录不存在：{options.desktop}")

    if not options.shortcuts_only:
        print("== 装到 " + str(options.applications) + " ==")
        install_apps(options.applications)

    print("== 桌面快捷按钮 ==")
    place_shortcuts(options.applications, options.desktop, options.force_shortcuts)
    print("\n完成。按钮上「合盖不休」的含义见 docs/architecture.md。")


if __name__ == "__main__":
    main()
