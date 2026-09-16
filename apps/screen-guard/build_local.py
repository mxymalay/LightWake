#!/usr/bin/env python3
"""Build signed local ScreenGuard apps without installing or launching them."""

from __future__ import annotations

import hashlib
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
# 工具链定位在 scripts/swift_toolchain.py：xcrun 被 Xcode 许可证挡住时它退回直调。
# 这个脚本在子目录里，所以得自己把 scripts/ 挂上 sys.path。
sys.path.insert(0, str(ROOT.parents[1] / "scripts"))
import swift_toolchain  # noqa: E402

BUILD = ROOT / "build"
SOURCES = ["GuardState.swift", "ControlStore.swift", "ScreenGuard.swift", "ScreenButtonState.swift", "ScreenButtonController.swift", "ScreenInputRules.swift", "ScreenInputRuntime.swift", "InputRulesSettingsView.swift", "QuietProtection.swift", "QuietProtectionSettings.swift", "Main.swift"]
# 只有一个 app。以前是四个（关闭屏幕 / 开启屏幕 / 轻醒按键 / 轻醒设置），
# 同一个可执行文件各存一份、靠 Info.plist 里的 ScreenGuardRole 分工；
# 3.0 起合成一个常驻 app：双击它切换熄屏模式，其余入口收进菜单栏，
# 按键规则走 lightwake:// URL。
APPS = [
    ("轻醒.app", "local.xy.lightwake", "LightWake-Info.plist"),
]
VERSION = "3.0.0"
BUILD_NUMBER = "13"
QUIET_RESOURCES = ["quiet_service_guard.py", "quiet_desktop_check.py", "quiet-sky.mjs"]


def run(*arguments: str | Path) -> None:
    command = [str(argument) for argument in arguments]
    print(shlex.join(command), flush=True)
    subprocess.run(command, check=True)


def read_plist(app: Path) -> dict:
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)


def icon_path(app: Path, info: dict) -> Path:
    name = info["CFBundleIconFile"]
    if not name.endswith(".icns"):
        name += ".icns"
    return app / "Contents/Resources" / name


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    app_metadata = []
    for name, identifier, plist_name in APPS:
        plist_path = ROOT / "resources" / plist_name
        with plist_path.open("rb") as stream:
            info = plistlib.load(stream)
        if (
            info.get("CFBundleExecutable") != "ScreenGuard"
            or info.get("CFBundleIdentifier") != identifier
        ):
            raise RuntimeError(f"Unexpected bundle identity or executable: {plist_path}")
        app_metadata.append((name, info))

    for source in SOURCES:
        if not (ROOT / source).is_file():
            raise FileNotFoundError(ROOT / source)
    for name in QUIET_RESOURCES:
        if not (ROOT / "resources/quiet-desktop" / name).is_file():
            raise FileNotFoundError(name)

    swift_command = swift_toolchain.swift_compile_command()
    BUILD.mkdir(parents=True, exist_ok=True)

    # Sign and verify all staging bundles before replacing previous build output.
    with tempfile.TemporaryDirectory(prefix=".staging-", dir=BUILD) as temporary:
        staging = Path(temporary)
        executable = staging / "ScreenGuard"
        run(
            *swift_command,
            "-O",
            "-target", "arm64-apple-macosx26.0",
            "-framework", "AppKit",
            "-framework", "IOKit",
            *(ROOT / source for source in SOURCES),
            "-o", executable,
        )
        run(swift_toolchain.lipo(), executable, "-verify_arch", "arm64")

        # Generate every icon size from the checked-in vector drawing source.
        # No installed applications or cached build outputs are needed.
        icon_generator = staging / "MakeIcons"
        run(*swift_command, "-O", ROOT / "MakeIcons.swift", "-o", icon_generator)
        icons = staging / "icons"
        icons.mkdir()
        run(icon_generator, icons)
        # 单 app 只用得上 off 图标（Finder 里那个）；on 图标留作 MakeIcons 的输出
        run(
            "/usr/bin/iconutil", "--convert", "icns",
            icons / "off.iconset", "--output", icons / "off.icns",
        )

        staged_apps = []
        for name, original_info in app_metadata:
            app = staging / name
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            executable_path = app / "Contents/MacOS/ScreenGuard"
            shutil.copy2(executable, executable_path)
            executable_path.chmod(0o755)

            info = dict(original_info)
            info["CFBundleShortVersionString"] = VERSION
            info["CFBundleVersion"] = BUILD_NUMBER
            generated_icon = icons / "off.icns"
            shutil.copy2(generated_icon, icon_path(app, info))
            quiet = app / "Contents/Resources/quiet-desktop"
            quiet.mkdir()
            for resource in QUIET_RESOURCES:
                origin = ROOT / "resources/quiet-desktop" / resource
                shutil.copy2(origin, quiet / resource)
                if digest(origin) != digest(quiet / resource):
                    raise RuntimeError(f"Quiet protection resource mismatch: {resource}")
            plist_path = app / "Contents/Info.plist"
            with plist_path.open("wb") as stream:
                plistlib.dump(info, stream, sort_keys=False)
            run("/usr/bin/plutil", "-lint", plist_path)
            run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app)
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)

            if read_plist(app) != info:
                raise RuntimeError(f"Bundle metadata verification failed: {app}")
            if digest(icon_path(app, info)) != digest(generated_icon):
                raise RuntimeError(f"Generated icon copy verification failed: {app}")
            staged_apps.append(app)

        for app in staged_apps:
            destination = BUILD / app.name
            if destination.is_symlink():
                destination.unlink()
            elif destination.exists():
                shutil.rmtree(destination)
            app.rename(destination)
            print(f"Built {destination} ({VERSION}, build {BUILD_NUMBER})", flush=True)
        shutil.copy2(executable, BUILD / "ScreenGuard")


if __name__ == "__main__":
    main()
