#!/usr/bin/env python3
"""Build signed local ScreenGuard apps without installing or launching them."""

from __future__ import annotations

import hashlib
import plistlib
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
SOURCES = ["GuardState.swift", "ControlStore.swift", "ScreenGuard.swift", "ScreenButtonState.swift", "ScreenButtonController.swift", "ScreenInputRules.swift", "ScreenInputRuntime.swift", "InputRulesSettingsView.swift", "QuietProtection.swift", "QuietProtectionSettings.swift", "Main.swift"]
APPS = [
    ("关闭屏幕.app", "local.xy.turn-off-display", "off", "Off-Info.plist"),
    ("开启屏幕.app", "local.xy.turn-on-display", "on", "On-Info.plist"),
    ("轻醒按键.app", "local.xy.screen-guard-control", "controller", "Controller-Info.plist"),
    ("轻醒设置.app", "local.xy.lightwake-settings", "settings", "Settings-Info.plist"),
]
VERSION = "2.5.0"
BUILD_NUMBER = "8"
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
    for name, identifier, role, plist_name in APPS:
        plist_path = ROOT / "resources" / plist_name
        with plist_path.open("rb") as stream:
            info = plistlib.load(stream)
        if (
            info.get("CFBundleExecutable") != "ScreenGuard"
            or info.get("CFBundleIdentifier") != identifier
            or info.get("ScreenGuardRole") != role
        ):
            raise RuntimeError(f"Unexpected bundle identity or executable: {plist_path}")
        app_metadata.append((name, role, info))

    for source in SOURCES:
        if not (ROOT / source).is_file():
            raise FileNotFoundError(ROOT / source)
    for name in QUIET_RESOURCES:
        if not (ROOT / "resources/quiet-desktop" / name).is_file():
            raise FileNotFoundError(name)

    sdk = subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    swiftc = subprocess.check_output(
        ["/usr/bin/xcrun", "--find", "swiftc"], text=True
    ).strip()
    BUILD.mkdir(parents=True, exist_ok=True)

    # Sign and verify all staging bundles before replacing previous build output.
    with tempfile.TemporaryDirectory(prefix=".staging-", dir=BUILD) as temporary:
        staging = Path(temporary)
        executable = staging / "ScreenGuard"
        run(
            swiftc,
            "-O",
            "-sdk", sdk,
            "-target", "arm64-apple-macosx26.0",
            "-framework", "AppKit",
            "-framework", "IOKit",
            *(ROOT / source for source in SOURCES),
            "-o", executable,
        )
        run("/usr/bin/lipo", executable, "-verify_arch", "arm64")

        # Generate every icon size from the checked-in vector drawing source.
        # No installed applications or cached build outputs are needed.
        icon_generator = staging / "MakeIcons"
        run(swiftc, "-O", "-sdk", sdk, ROOT / "MakeIcons.swift", "-o", icon_generator)
        icons = staging / "icons"
        icons.mkdir()
        run(icon_generator, icons)
        for role in ("off", "on"):
            run(
                "/usr/bin/iconutil", "--convert", "icns",
                icons / f"{role}.iconset", "--output", icons / f"{role}.icns",
            )

        staged_apps = []
        for name, role, original_info in app_metadata:
            app = staging / name
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            executable_path = app / "Contents/MacOS/ScreenGuard"
            shutil.copy2(executable, executable_path)
            executable_path.chmod(0o755)

            info = dict(original_info)
            info["CFBundleShortVersionString"] = VERSION
            info["CFBundleVersion"] = BUILD_NUMBER
            generated_icon = icons / f"{'off' if role in ('controller', 'settings') else role}.icns"
            shutil.copy2(generated_icon, icon_path(app, info))
            if role == "settings":
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
